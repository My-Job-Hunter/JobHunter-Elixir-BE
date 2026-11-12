defmodule Core.Approvals.Decide do
  @moduledoc """
  Deciding an approval (AQ-07 §6, QP7-5…7, QP7-14): a reviewer's decision
  on a version (`decide/4`, through `Core.Approvals.Act`), or the system's
  at `auto_approve_at` (`auto_approve/3`). One transaction, **under the
  approval's row lock**: the decision (one per slot per version), then
  `Core.Approvals.Rule`; on an outcome the approval moves, its
  `approval_decided` row is written, the requester and the other
  reviewers are told and the reminders dropped; on **approved** the kind's
  effect runs in the same transaction (`Core.Approvals.Effects`).

  **A stale decision** — a version that isn't the current one, an
  approval no longer pending, or a slot that has decided already — is
  `{:error, {:approval_not_pending, %{state, version}}}` (409), checked
  before and again under the lock; a caller who sees it but holds no slot
  is `:not_reviewer` (403, `Core.Access.Approvals`).
  """

  alias Core.Approvals
  alias Core.Approvals.{Ask, Effects, Notices, Reminders, Rule, Sheet}
  alias Core.Audit
  alias Core.Leads
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Accounts
  alias Data.Approvals, as: Store
  alias Data.Approvals.Approval
  alias Data.Scope

  @doc """
  `POST /approvals/:id/decide {decision, note?, version}`: the caller's
  open slot decides `version`; a note is required for `changes_requested`
  and `rejected`. Answers the **approval**.
  """
  @spec decide(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def decide(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, a} <- Approvals.fetch(scope, :decide, id),
         {:ok, version} <- version(params["version"]),
         :ok <- current(a, version),
         {:ok, decision} <- decision(params["decision"]),
         {:ok, note} <- note(decision, params["note"]),
         {:ok, slot} <- my_slot(scope, a) do
      fn -> decided(scope, a.id, [slot.id], {decision, note, version}, now) end
      |> Write.commit()
      |> Approvals.answer(scope, now)
    end
  end

  defp version(nil), do: {:error, {:missing, [:version]}}
  defp version(n) when is_integer(n) and n >= 1, do: {:ok, n}

  defp version(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> version(i)
      _bad -> Leads.invalid("version", "is the version's number")
    end
  end

  defp version(_n), do: Leads.invalid("version", "is the version's number")

  defp current(%Approval{state: :pending, version_count: n}, n), do: :ok
  defp current(a, _version), do: stale(a)

  defp stale(a),
    do: {:error, {:approval_not_pending, %{state: a.state, version: a.version_count}}}

  defp decision(nil), do: {:error, {:missing, [:decision]}}

  defp decision(value) do
    case Ask.pick(value, [:approved, :changes_requested, :rejected]) do
      nil -> Leads.invalid("decision", "is approved, changes_requested or rejected")
      decision -> {:ok, decision}
    end
  end

  defp note(:approved, note), do: {:ok, Leads.blank(note) && String.trim(note)}

  defp note(_refusal, note) do
    case Leads.blank(note) do
      nil ->
        Leads.invalid("note", "is required")

      text ->
        if String.length(text) > 2000,
          do: Leads.invalid("note", "is too long (2,000 at most)"),
          else: {:ok, String.trim(text)}
    end
  end

  # The caller's open slot on the current version: one already decided is stale.
  defp my_slot(scope, a) do
    open = Sheet.open_slots(a)

    pick =
      if Scope.customer?(scope),
        do: Enum.find(open, &(&1.slot == :customer)),
        else:
          Enum.find(open, &(&1.slot == :user and &1.user_id == Scope.user_id(scope))) ||
            Enum.find(
              open,
              &(&1.slot == :team_lead and Scope.team_role(scope, a.team_id) == :lead)
            )

    if pick, do: {:ok, pick}, else: stale(a)
  end

  # Inside the transaction, under the row's lock: the decisions, then the rule.
  defp decided(scope, id, slot_ids, {decision, note, version}, now) do
    locked = Store.lock(id)

    if locked.state != :pending or locked.version_count != version do
      {:error, {:approval_not_pending, %{state: locked.state, version: locked.version_count}}}
    else
      with :ok <- write_decisions(scope, id, slot_ids, {decision, note, version}, now) do
        a = Store.get_for_system(id)
        outcome = Rule.outcome(a.rule, a.reviewers, Sheet.decisions_on(a, version))

        {:ok, _audit} =
          Audit.record(scope, "decided", a,
            after: %{"decision" => to_string(decision), "version" => version, "note" => note},
            now: now
          )

        settle(scope, a, outcome, note, now)
      end
    end
  end

  defp write_decisions(scope, id, slot_ids, {decision, note, version}, now) do
    Enum.reduce_while(slot_ids, :ok, fn slot_id, :ok ->
      case Store.add_decision(%{
             approval_id: id,
             approval_reviewer_id: slot_id,
             version_number: version,
             decision: decision,
             note: note,
             decided_by_user_id: Scope.user_id(scope),
             decided_at: now
           }) do
        {:ok, _d} -> {:cont, :ok}
        {:error, changeset} -> {:halt, already_or(changeset, id)}
      end
    end)
  end

  defp already_or(%Ecto.Changeset{errors: errors} = changeset, id) do
    if Keyword.has_key?(errors, :approval_reviewer_id),
      do: stale(Store.get_for_system(id)),
      else: {:error, changeset}
  end

  defp settle(_scope, a, :pending, _note, now) do
    :ok = Store.touch(a.id, now)
    {:ok, a, Realtime.approval_changed(a)}
  end

  defp settle(scope, a, outcome, note, now) do
    {effect, effect_note} =
      if outcome == :approved, do: Effects.run(a, by(scope, a), now), else: {:none, nil}

    with {:ok, done} <-
           Store.update(a, %{
             state: outcome,
             decided_at: now,
             effect: effect,
             effect_note: effect_note,
             effect_at: if(effect == :none, do: nil, else: now)
           }) do
      done = Store.reload(done)

      ledger? =
        Approvals.ledger(
          scope,
          done,
          :approval_decided,
          %{to_label: Sheet.state_words(outcome), note: note},
          now
        )

      :ok = Reminders.drop(done.id)

      {:ok, done,
       [Notices.decided(scope, done), Realtime.approval_changed(done, ledger: ledger?)]}
    end
  end

  # Who approved it, as the effect's words say: the customer by their name.
  defp by(scope, a) do
    cond do
      is_nil(Scope.user_id(scope)) ->
        "automatically"

      Scope.customer?(scope) ->
        a.customer.display_name

      true ->
        scope
        |> Scope.user_id()
        |> Accounts.get_user()
        |> then(&((&1 && &1.person.display_name) || "a team lead"))
    end
  end

  # ── Auto-approve ────────────────────────────────────────────────────────────

  @doc """
  Auto-approve (§9, QP7-14): an approval still pending at `at` (its
  `auto_approve_at`, as the job was planned) and due by `now` is approved
  by the system on every open slot. Answers `:approved`, or why it did
  nothing (`:gone`, `:moved`, `:early`).
  """
  @spec auto_approve(term(), DateTime.t(), DateTime.t()) :: :approved | :gone | :moved | :early
  def auto_approve(id, %DateTime{} = at, %DateTime{} = now) do
    with %Approval{} = a <- Store.get_for_system(id) || :gone,
         :ok <- planned(a, at),
         :ok <- if(DateTime.compare(at, now) != :gt, do: :ok, else: :early) do
      scope = Scope.system(%{id: a.organisation_id})
      note = "Approved automatically after #{hours(a)} hours."
      slots = Enum.map(Sheet.open_slots(a), & &1.id)

      work = fn -> decided(scope, a.id, slots, {:approved, note, a.version_count}, now) end
      if match?({:ok, _a}, Write.commit(work)), do: :approved, else: :moved
    end
  end

  defp planned(%Approval{state: :pending, auto_approve_at: %DateTime{} = at}, planned),
    do: if(DateTime.compare(at, planned) == :eq, do: :ok, else: :moved)

  defp planned(_a, _planned), do: :moved

  defp hours(a) do
    since = if a.version_count == 1, do: a.submitted_at, else: Sheet.current(a).inserted_at
    round(DateTime.diff(a.auto_approve_at, since, :second) / 3600)
  end

  @doc "Every pending approval whose auto-approve time has come by `now`: the dev clock's catch-up. Answers how many."
  @spec auto_approve_due(DateTime.t()) :: %{approved: non_neg_integer()}
  def auto_approve_due(%DateTime{} = now) do
    %{
      approved:
        now
        |> Store.auto_approvable_for_system()
        |> Enum.count(&(auto_approve(&1.id, &1.auto_approve_at, now) == :approved))
    }
  end
end
