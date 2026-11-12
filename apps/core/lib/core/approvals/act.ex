defmodule Core.Approvals.Act do
  @moduledoc """
  The verbs that move an approval (AQ-07 §6), each **one transaction** with
  its ledger row (on the lead, when it has one), audit row, notifications
  and, after commit, `approval_changed`:

  | Verb | From | Does |
  |---|---|---|
  | `submit` | draft | → pending; `submitted_at`; the reviewers told; `approval_requested`; the due reminders and auto-approve planned |
  | `decide {decision, note?, version}` | pending, an open slot | `Core.Approvals.Decide`: the slot's decision on that version, `Core.Approvals.Rule`, the effect on **approved** |
  | `revise {body_md, proposed?, media_ids?}` | changes requested (or pending, by the requester) | a new version (the files and the proposed value carried forward unless sent); → pending; every slot open again |
  | `withdraw` | draft, pending, changes requested | → withdrawn |
  | `sent` | an approved reply, proposal or cover letter, *Ready to send* | a reply's outbound message recorded (P6's `manual`, *Replies to* the message it answers); → `sent` |
  | `auto_approve` (a job) | pending, at `auto_approve_at` | `Core.Approvals.Decide`: approved by the system on every open slot |
  | `expire` (the hourly sweep) | pending, three days past due | → expired; the requester told |
  """

  alias Core.Approvals
  alias Core.Approvals.{Ask, Decide, Notices, Policies, Reminders, Sheet}
  alias Core.Audit
  alias Core.Conversations.Messages
  alias Core.Leads
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Approvals, as: Store
  alias Data.Approvals.{Approval, Version}
  alias Data.Scope

  @sent_kinds [:reply, :proposal, :cover_letter]
  @expire_after 3 * 86_400

  # ── Submit ──────────────────────────────────────────────────────────────────

  @doc "`POST /approvals/:id/submit`: a draft → pending."
  @spec submit(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def submit(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, a} <- Approvals.fetch(scope, :submit, id),
         :ok <- Approvals.in_state(a, [:draft], "This approval was sent already.") do
      fn -> submitted(scope, a, now) end
      |> Write.commit()
      |> Approvals.answer(scope, now)
    end
  end

  @doc false
  # Inside a transaction: the draft submitted (also `POST /approvals {submit: true}`).
  def submitted(scope, a, now) do
    auto_at = Policies.auto_approve_at(a.customer_id, a.approval_kind, now)

    with {:ok, pending} <-
           Store.update(a, %{state: :pending, submitted_at: now, auto_approve_at: auto_at}) do
      pending = Store.reload(pending)
      ledger? = requested(scope, pending, now)

      {:ok, _audit} =
        Audit.record(scope, "submitted", pending, after: Approvals.snapshot(pending), now: now)

      :ok = Reminders.plan(pending, now)

      {:ok, pending,
       [Notices.requested(scope, pending), Realtime.approval_changed(pending, ledger: ledger?)]}
    end
  end

  # `approval_requested` on the lead, `to_label` the title.
  defp requested(scope, a, now),
    do: Approvals.ledger(scope, a, :approval_requested, %{to_label: a.title}, now)

  # ── Decide, auto-approve (`Core.Approvals.Decide`) ──────────────────────────

  @doc "`POST /approvals/:id/decide {decision, note?, version}` (`Core.Approvals.Decide.decide/4`)."
  defdelegate decide(scope, id, params, now), to: Decide

  @doc "Auto-approve, a job's work (`Core.Approvals.Decide.auto_approve/3`)."
  defdelegate auto_approve(id, at, now), to: Decide

  @doc "Every auto-approve due by `now` (`Core.Approvals.Decide.auto_approve_due/1`)."
  defdelegate auto_approve_due(now), to: Decide

  # ── Revise ──────────────────────────────────────────────────────────────────

  @doc """
  `POST /approvals/:id/revise {body_md, proposed?, media_ids?}`: a new
  version — the proposed value and the files carried forward unless sent —
  pending again, every slot open. From changes requested (the requester or
  a team lead), or pending (the requester alone).
  """
  @spec revise(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def revise(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, a} <- Approvals.fetch(scope, :revise, id),
         :ok <- revisable(scope, a),
         :ok <-
           if(Map.has_key?(params, "body_md"), do: :ok, else: {:error, {:missing, [:body_md]}}),
         {:ok, body} <- Ask.body(params["body_md"]),
         {:ok, proposed} <-
           carried(params, "proposed", a, &Ask.proposed(a.approval_kind, &1, Approvals.about(a))),
         {:ok, media} <- carried(params, "media_ids", a, &Ask.media(scope, &1, held(a))) do
      fn -> revised(scope, a, body, proposed, media, now) end
      |> Write.commit()
      |> Approvals.answer(scope, now)
    end
  end

  defp revisable(_scope, %Approval{state: :changes_requested}), do: :ok

  defp revisable(scope, %Approval{state: :pending} = a) do
    if a.requested_by_user_id == Scope.user_id(scope),
      do: :ok,
      else: Leads.invalid("state", "While it waits, only whoever asked can revise it.")
  end

  defp revisable(_scope, a),
    do: Leads.invalid("state", "This approval is #{lower(a.state)}; it can't be revised.")

  defp carried(params, key, _a, fun) do
    if Map.has_key?(params, key), do: fun.(params[key]), else: {:ok, :carried}
  end

  defp held(a),
    do: a.versions |> Enum.flat_map(& &1.media_links) |> Enum.map(& &1.media_id) |> Enum.uniq()

  defp revised(scope, a, body, proposed, media, now) do
    before = Sheet.current(a)
    number = a.version_count + 1

    proposed =
      if proposed == :carried,
        do: Map.take(before, Version.proposed()),
        else: Map.merge(Approvals.blank_proposed(), proposed)

    media = if media == :carried, do: Enum.map(before.media_links, & &1.media_id), else: media

    with {:ok, v} <-
           Store.add_version(
             Map.merge(proposed, %{
               approval_id: a.id,
               approval_kind: a.approval_kind,
               number: number,
               body_md: body,
               created_by_user_id: Scope.user_id(scope),
               inserted_at: now
             })
           ),
         :ok <- Store.put_media(v.id, media),
         {:ok, pending} <-
           Store.update(a, %{
             state: :pending,
             version_count: number,
             decided_at: nil,
             auto_approve_at: Policies.auto_approve_at(a.customer_id, a.approval_kind, now)
           }) do
      pending = Store.reload(pending)
      ledger? = requested(scope, pending, now)

      {:ok, _audit} =
        Audit.record(scope, "revised", pending,
          before: Approvals.snapshot(a),
          after: Approvals.snapshot(pending),
          now: now
        )

      :ok = Reminders.drop(a.id)
      :ok = Reminders.plan(pending, now)

      {:ok, pending,
       [Notices.requested(scope, pending), Realtime.approval_changed(pending, ledger: ledger?)]}
    end
  end

  # ── Withdraw ────────────────────────────────────────────────────────────────

  @doc "`POST /approvals/:id/withdraw`: draft, pending or changes requested → withdrawn."
  @spec withdraw(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def withdraw(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, a} <- Approvals.fetch(scope, :withdraw, id),
         :ok <-
           Approvals.in_state(
             a,
             [:draft, :pending, :changes_requested],
             "This approval is #{lower(a.state)}; it can't be withdrawn."
           ) do
      fn -> withdrawn(scope, a, now) end
      |> Write.commit()
      |> Approvals.answer(scope, now)
    end
  end

  defp withdrawn(scope, a, now) do
    with {:ok, gone} <- Store.update(a, %{state: :withdrawn}) do
      gone = Store.reload(gone)

      ledger? =
        not is_nil(a.submitted_at) and
          Approvals.ledger(scope, gone, :approval_withdrawn, %{to_label: a.title}, now)

      {:ok, _audit} =
        Audit.record(scope, "withdrawn", gone,
          before: Approvals.snapshot(a),
          after: Approvals.snapshot(gone),
          now: now
        )

      :ok = Reminders.drop(a.id)
      {:ok, gone, Realtime.approval_changed(gone, ledger: ledger?)}
    end
  end

  # ── Recorded as sent ────────────────────────────────────────────────────────

  @doc """
  `POST /approvals/:id/sent {}`: an approved reply's outbound message
  recorded (P6's `manual`, *Replies to* the message it answers, the current
  version's words); a proposal or cover letter only marked. The effect is
  `sent`. Nothing is sent by itself (P9b).
  """
  @spec sent(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def sent(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, a} <- Approvals.fetch(scope, :sent, id),
         :ok <- sendable(a) do
      fn -> recorded(scope, a, now) end
      |> Write.commit()
      |> Approvals.answer(scope, now)
    end
  end

  defp sendable(%Approval{state: :approved, effect: :ready, approval_kind: kind})
       when kind in @sent_kinds,
       do: :ok

  defp sendable(%Approval{effect: :sent}),
    do: Leads.invalid("effect", "This was recorded as sent already.")

  defp sendable(_a),
    do:
      Leads.invalid(
        "state",
        "Only an approved reply, proposal or cover letter is recorded as sent."
      )

  defp recorded(scope, a, now) do
    with :ok <- message(scope, a, now),
         {:ok, done} <- Store.update(a, %{effect: :sent, effect_at: now}) do
      done = Store.reload(done)

      {:ok, _audit} =
        Audit.record(scope, "sent", done,
          before: Approvals.snapshot(a),
          after: Approvals.snapshot(done),
          now: now
        )

      {:ok, done, Realtime.approval_changed(done)}
    end
  end

  defp message(scope, %Approval{approval_kind: :reply} = a, now) do
    target =
      cond do
        a.conversation_id ->
          %{"conversation_id" => a.conversation_id, "parent_message_id" => a.message_id}

        a.lead_id ->
          %{"lead_id" => a.lead_id}
      end

    params =
      Map.merge(target, %{
        "direction" => "out",
        "from" => %{"kind" => "user"},
        "sent_at" => DateTime.to_iso8601(now),
        "body_md" => Sheet.current(a).body_md
      })

    case Messages.create(scope, params, now) do
      {:ok, _conversation} -> :ok
      error -> error
    end
  end

  defp message(_scope, _a, _now), do: :ok

  # ── The expiry ──────────────────────────────────────────────────────────────

  @doc """
  The expiry sweep (§9, QP7-12; hourly, idempotent): every approval still
  pending three days past its due date → expired, the requester told. An
  approval with no due date never expires. Answers how many.
  """
  @spec expire(DateTime.t()) :: %{expired: non_neg_integer()}
  def expire(%DateTime{} = now) do
    %{
      expired:
        now
        |> DateTime.add(-@expire_after, :second)
        |> Store.expirable_for_system()
        |> Enum.count(&(expired(&1, now) == :expired))
    }
  end

  defp expired(a, now) do
    case Write.commit(fn -> expire_one(a, now) end) do
      {:ok, %Approval{}} -> :expired
      _moved -> :moved
    end
  end

  defp expire_one(a, now) do
    scope = Scope.system(%{id: a.organisation_id})

    if Store.lock(a.id).state == :pending do
      {:ok, gone} = Store.update(a, %{state: :expired})
      gone = Store.reload(gone)

      {:ok, _audit} =
        Audit.record(scope, "expired", gone,
          before: Approvals.snapshot(a),
          after: Approvals.snapshot(gone),
          now: now
        )

      :ok = Reminders.drop(a.id)
      {:ok, gone, [Notices.expired(scope, gone), Realtime.approval_changed(gone)]}
    else
      {:ok, :moved}
    end
  end

  defp lower(state), do: state |> Sheet.state_words() |> String.downcase()
end
