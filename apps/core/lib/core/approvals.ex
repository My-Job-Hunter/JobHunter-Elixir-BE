defmodule Core.Approvals do
  @moduledoc """
  Approvals (AQ-07 P7.0–P7.3): read — the page, the count, a lead's, the
  sheet — and asked: **draft** (`POST /approvals`, version 1 and the slots
  from the customer's policy; `submit: true` submits it in the same
  transaction) and **edit** (`PATCH`, a draft only). The verbs that move
  one are `Core.Approvals.Act`; the outcome `Core.Approvals.Rule` (pure);
  the diff `Core.Approvals.Diff` (pure); the policies
  `Core.Approvals.Policies`; what approval does `Core.Approvals.Effects`;
  who is told `Core.Approvals.Notices`; the due reminders and auto-approve
  `Core.Approvals.Reminders`; the comments `Core.Approvals.Comments`; the
  shapes `Core.Approvals.Sheet`; what a body carries `Core.Approvals.Ask`.

  Every function takes a `%Data.Scope{}` first and asks `Core.Access`
  (`Core.Access.Approvals`); an approval the caller may not see is
  `:not_found`. Every write is one transaction with its audit row (and,
  for the verbs, its ledger row and notifications), and broadcasts
  `approval_changed` after commit.
  """

  alias Core.Access
  alias Core.Approvals.{Act, Ask, Sheet}
  alias Core.Audit
  alias Core.Leads
  alias Core.Leads.Ledger
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Approvals, as: Store
  alias Data.Approvals.{Approval, Version}
  alias Data.Scope
  alias Data.Vocabulary

  @page 50
  @kinds Vocabulary.approval_kinds() |> Enum.map(&String.to_atom/1)
  @states Vocabulary.approval_states() |> Enum.map(&String.to_atom/1)
  @audited ~w(approval_kind state title lead_id profile_id message_id conversation_id rule due_at
              auto_approve_at requested_by_user_id submitted_at decided_at version_count effect
              effect_note)a

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The approval behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Approval.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Approval{} = a <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:approval, Sheet.subject(a)}),
         do: {:ok, a}
  end

  @doc "`GET /approvals/:id`: the **approval** as `scope` reads it."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, a} <- fetch(scope, :read, id), do: {:ok, Sheet.approval(scope, a, now)}
  end

  @doc """
  `GET /approvals?team_id&tab=waiting|asked|all&kind&customer_id&lead_id&state&due=overdue|week&cursor`
  (the console: one team's; `all` a team lead's or the system admin's) and
  the portal's `GET /approvals?tab=waiting|all&lead_id` (the customer's
  own, with a customer slot). *Waiting on me* is soonest due first; the rest newest
  first. Answers the **page**.
  """
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, tab, where} <- where(scope, params),
         {:ok, narrow} <- narrow(params),
         {:ok, offset} <- cursor(params["cursor"]) do
      items =
        (where ++ narrow.store)
        |> Store.list()
        |> Enum.filter(
          &(readable?(scope, &1) and in_tab?(scope, tab, &1) and due?(narrow.due, &1, now))
        )
        |> order(tab)

      {:ok,
       %{
         items: items |> Enum.slice(offset, @page) |> Enum.map(&Sheet.row(scope, &1, now)),
         next_cursor: if(length(items) > offset + @page, do: encode(offset + @page))
       }}
    end
  end

  defp where(scope, params) do
    if Scope.customer?(scope) do
      with {:ok, tab} <- tab(params["tab"], ~w(waiting all)),
           do: {:ok, tab, [customer_id: Scope.customer_id(scope), customer_slot: true]}
    else
      with {:ok, team} <- Core.Jobs.team(scope, params),
           {:ok, tab} <- tab(params["tab"], ~w(waiting asked all)),
           :ok <- all_tab(scope, team, tab),
           do: {:ok, tab, [team_id: team.id]}
    end
  end

  defp tab(nil, _allowed), do: {:ok, :waiting}
  defp tab("", _allowed), do: {:ok, :waiting}

  defp tab(value, allowed) do
    if value in allowed,
      do: {:ok, Ask.pick(value, [:waiting, :asked, :all])},
      else: Leads.invalid("tab", "is #{Enum.join(allowed, ", ")}")
  end

  defp all_tab(scope, team, :all) do
    if Scope.admin?(scope) or Scope.team_role(scope, team.id) == :lead,
      do: :ok,
      else: {:error, {:forbidden, "Only a team lead can see all of the team's approvals."}}
  end

  defp all_tab(_scope, _team, _tab), do: :ok

  defp narrow(params) do
    with {:ok, kind} <- enum(params["kind"], @kinds, "kind"),
         {:ok, state} <- enum(params["state"], @states, "state"),
         {:ok, customer_id} <- uuid(params["customer_id"], "customer_id"),
         {:ok, lead_id} <- uuid(params["lead_id"], "lead_id"),
         {:ok, due} <- due_filter(params["due"]) do
      {:ok,
       %{store: [kind: kind, state: state, customer_id: customer_id, lead_id: lead_id], due: due}}
    end
  end

  defp readable?(scope, a), do: Access.can?(scope, :read, {:approval, Sheet.subject(a)})

  defp in_tab?(scope, :waiting, a), do: Sheet.waiting_on_me?(scope, a)

  defp in_tab?(scope, :asked, a),
    do: not is_nil(a.requested_by_user_id) and a.requested_by_user_id == Scope.user_id(scope)

  defp in_tab?(_scope, :all, _a), do: true

  defp due?(nil, _a, _now), do: true
  defp due?(:overdue, a, now), do: Sheet.overdue?(a, now)

  defp due?(:week, a, now),
    do:
      a.state == :pending and not is_nil(a.due_at) and
        DateTime.compare(a.due_at, DateTime.add(now, 7 * 86_400, :second)) != :gt

  defp due_filter(nil), do: {:ok, nil}
  defp due_filter(""), do: {:ok, nil}
  defp due_filter("overdue"), do: {:ok, :overdue}
  defp due_filter("week"), do: {:ok, :week}
  defp due_filter(_other), do: Leads.invalid("due", "is overdue or week")

  # Waiting on me: soonest due first (none last), then oldest asked; else newest first.
  defp order(items, :waiting) do
    Enum.sort_by(items, fn a ->
      {is_nil(a.due_at), a.due_at && DateTime.to_unix(a.due_at, :microsecond),
       a.submitted_at && DateTime.to_unix(a.submitted_at, :microsecond)}
    end)
  end

  defp order(items, _tab), do: items

  @doc """
  `GET /approvals/count?team_id?`: `{waiting_on_me}` for the nav, in both
  apps — the pending approvals with an open slot the caller may take.
  """
  @spec count(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def count(%Scope{} = scope, params) do
    params = Leads.stringify(params)

    with {:ok, pending} <- pending(scope, params) do
      {:ok, %{waiting_on_me: Enum.count(pending, &Sheet.waiting_on_me?(scope, &1))}}
    end
  end

  defp pending(scope, params) do
    cond do
      Scope.customer?(scope) ->
        {:ok,
         Store.list(customer_id: Scope.customer_id(scope), customer_slot: true, state: :pending)}

      params["team_id"] not in [nil, ""] ->
        with {:ok, team} <- Core.Jobs.team(scope, params),
             do: {:ok, Store.list(team_id: team.id, state: :pending)}

      Scope.user_id(scope) ->
        {:ok, Store.pending_for(Scope.team_ids(scope), Scope.user_id(scope))}

      true ->
        {:ok, []}
    end
  end

  @doc "`GET /leads/:id/approvals` (both apps): the lead's approvals the caller sees, as **approval rows**, newest first."
  @spec for_lead(Scope.t(), term(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def for_lead(%Scope{} = scope, lead_id, %DateTime{} = now) do
    with {:ok, lead} <- Leads.fetch(scope, :read, lead_id),
         do: {:ok, Enum.map(seen_on(scope, lead), &Sheet.row(scope, &1, now))}
  end

  @doc "How many of a lead's approvals the caller sees: the lead page's Approvals tab."
  @spec count_for_lead(Scope.t(), map()) :: non_neg_integer()
  def count_for_lead(%Scope{} = scope, lead), do: length(seen_on(scope, lead))

  defp seen_on(scope, lead) do
    lead.id
    |> Store.for_lead()
    |> Enum.filter(&readable?(scope, &1))
  end

  # ── Draft ───────────────────────────────────────────────────────────────────

  @doc """
  `POST /approvals {team_id, approval_kind, title, lead_id?, profile_id?,
  conversation_id?, message_id?, body_md, proposed?, media_ids, due_at?,
  slots?, rule?, submit?}`: a draft with version 1 and its slots (the
  customer's policy, or the requester's for an ad hoc kind); nobody is
  told. `submit: true` submits it at once. Answers the **approval**.
  """
  @spec draft(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def draft(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, kind} <- Ask.kind(params["approval_kind"]),
         {:ok, about} <- Ask.about(scope, kind, params),
         {:ok, title} <- Ask.title(params["title"]),
         {:ok, body} <- Ask.body(params["body_md"]),
         {:ok, proposed} <- Ask.proposed(kind, params["proposed"], about),
         {:ok, media} <- Ask.media(scope, params["media_ids"], []),
         {:ok, due} <- Ask.due(params["due_at"], now),
         {:ok, slots, rule} <- Ask.slots(scope, about, kind, params) do
      attrs = %{
        organisation_id: Scope.organisation_id(scope),
        team_id: about.team.id,
        customer_id: about.customer.id,
        approval_kind: kind,
        state: :draft,
        title: title,
        lead_id: about.lead && about.lead.id,
        profile_id: about.profile && about.profile.id,
        conversation_id: about[:conversation] && about.conversation.id,
        message_id: about[:message] && about.message.id,
        rule: rule,
        due_at: due,
        requested_by_user_id: Scope.user_id(scope),
        version_count: 1
      }

      version = Map.merge(proposed, %{body_md: body, created_by_user_id: Scope.user_id(scope)})
      submit? = params["submit"] in [true, "true"]

      fn -> drafted(scope, attrs, version, media, slots, submit?, now) end
      |> Write.commit()
      |> answer(scope, now)
    end
  end

  defp drafted(scope, attrs, version, media, slots, submit?, now) do
    with {:ok, a} <- Store.create(attrs),
         {:ok, v} <-
           Store.add_version(
             Map.merge(version, %{
               approval_id: a.id,
               approval_kind: a.approval_kind,
               number: 1,
               inserted_at: now
             })
           ),
         :ok <- Store.put_media(v.id, media),
         :ok <- Store.put_reviewers(a.id, slots) do
      a = Store.reload(a)
      {:ok, _audit} = Audit.record(scope, "created", a, after: snapshot(a), now: now)

      if submit?,
        do: Act.submitted(scope, a, now),
        else: {:ok, a, Realtime.approval_changed(a)}
    end
  end

  # ── Edit (a draft) ──────────────────────────────────────────────────────────

  @doc """
  `PATCH /approvals/:id` (a draft): any of `title, body_md, proposed,
  media_ids, due_at, slots, rule`, version 1 changed in place. Audited.
  """
  @spec edit(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def edit(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, a} <- fetch(scope, :edit, id),
         :ok <- in_state(a, [:draft], "Only a draft can be edited; revise it instead."),
         {:ok, changes} <- edits(scope, a, params, now) do
      fn -> edited(scope, a, changes, now) end
      |> Write.commit()
      |> answer(scope, now)
    end
  end

  defp edits(scope, a, params, now) do
    about = about(a)
    v = Sheet.current(a)
    held = Enum.map(v.media_links, & &1.media_id)

    with {:ok, title} <- maybe(params, "title", &Ask.title/1),
         {:ok, body} <- maybe(params, "body_md", &Ask.body/1),
         {:ok, proposed} <- maybe(params, "proposed", &Ask.proposed(a.approval_kind, &1, about)),
         {:ok, media} <- maybe(params, "media_ids", &Ask.media(scope, &1, held)),
         {:ok, due} <- maybe(params, "due_at", &Ask.due(&1, now)),
         {:ok, slots} <- slots(scope, a, about, params) do
      {:ok,
       %{
         approval:
           %{title: title, due_at: due} |> present(params, ~w(title due_at)) |> put_rule(slots),
         version:
           if(proposed == :absent, do: %{}, else: Map.merge(blank_proposed(), proposed))
           |> then(&if(body == :absent, do: &1, else: Map.put(&1, :body_md, body))),
         media: media,
         slots: slots
       }}
    end
  end

  defp maybe(params, key, fun),
    do: if(Map.has_key?(params, key), do: fun.(params[key]), else: {:ok, :absent})

  defp present(attrs, params, keys),
    do:
      Map.filter(attrs, fn {k, _v} ->
        to_string(k) in keys and Map.has_key?(params, to_string(k))
      end)

  defp put_rule(attrs, :absent), do: attrs
  defp put_rule(attrs, {_slots, rule}), do: Map.put(attrs, :rule, rule)

  defp slots(scope, a, about, params) do
    if Map.has_key?(params, "slots") or Map.has_key?(params, "rule") do
      raw = %{
        "slots" =>
          Map.get(
            params,
            "slots",
            Enum.map(a.reviewers, &%{"slot" => to_string(&1.slot), "user_id" => &1.user_id})
          ),
        "rule" => Map.get(params, "rule", to_string(a.rule))
      }

      with {:ok, slots, rule} <- Ask.slots(scope, about, a.approval_kind, raw),
           do: {:ok, {slots, rule}}
    else
      {:ok, :absent}
    end
  end

  defp edited(scope, a, changes, now) do
    v = Sheet.current(a)

    with {:ok, _a} <- Store.update(a, changes.approval),
         {:ok, _v} <- Store.update_version(v, changes.version),
         :ok <- if(changes.media == :absent, do: :ok, else: Store.put_media(v.id, changes.media)),
         :ok <- put_slots(a, changes.slots) do
      updated = Store.reload(a)
      :ok = audit_change(scope, a, updated, now)
      {:ok, updated, Realtime.approval_changed(updated)}
    end
  end

  defp put_slots(_a, :absent), do: :ok
  defp put_slots(a, {slots, _rule}), do: Store.put_reviewers(a.id, slots)

  @doc false
  # What an approval is about, as `Core.Approvals.Ask` reads it.
  def about(a), do: %{team: a.team, customer: a.customer, lead: a.lead, profile: a.profile}

  @doc false
  def blank_proposed, do: Map.new(Version.proposed(), &{&1, nil})

  # ── Helpers shared with the verbs ───────────────────────────────────────────

  @doc false
  # A verb's state check: a field error on `state`, in the doc's words.
  def in_state(%Approval{state: state}, allowed, words),
    do: if(state in allowed, do: :ok, else: Leads.invalid("state", words))

  @doc false
  # A ledger row on the approval's lead (none for a profile's), the
  # customer's to read when they hold a slot (QP7-19). Answers whether one
  # was written.
  def ledger(_scope, %Approval{lead_id: nil}, _kind, _attrs, _now), do: false

  def ledger(scope, a, kind, attrs, now) do
    visibility = if Enum.any?(a.reviewers, &(&1.slot == :customer)), do: :customer, else: :staff
    attrs = Map.merge(attrs, %{approval_id: a.id, visibility: visibility})
    _event = Ledger.record(scope, Data.Leads.reload(a.lead), kind, attrs, now)
    true
  end

  @doc "The approval just written, as `scope` reads it."
  @spec answer({:ok, Approval.t()} | {:error, term()}, Scope.t(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def answer({:ok, %Approval{} = a}, scope, now),
    do: {:ok, Sheet.approval(scope, Store.reload(a), now)}

  def answer(error, _scope, _now), do: error

  @doc false
  def snapshot(a) do
    a
    |> Audit.snapshot(@audited)
    |> Map.merge(%{
      "team_id" => a.team_id,
      "customer_id" => a.customer_id,
      "slots" => Enum.map(a.reviewers, &%{"slot" => to_string(&1.slot), "user_id" => &1.user_id})
    })
  end

  @doc false
  def audit_change(scope, before, updated, now) do
    old = snapshot(before)
    new = snapshot(updated)
    keys = for {k, v} <- new, old[k] != v, do: k

    if keys != [] do
      {:ok, _audit} =
        Audit.record(scope, "updated", updated,
          before: Map.take(old, keys),
          after: Map.take(new, keys),
          now: now
        )
    end

    :ok
  end

  defp enum(value, _allowed, _field) when value in [nil, ""], do: {:ok, nil}

  defp enum(value, allowed, field) do
    case Ask.pick(value, allowed) do
      nil -> Leads.invalid(field, "is not one of the list")
      atom -> {:ok, atom}
    end
  end

  defp uuid(value, _field) when value in [nil, ""], do: {:ok, nil}

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> Leads.invalid(field, "is not an id")
    end
  end

  defp encode(offset), do: Base.url_encode64("approvals:#{offset}", padding: false)

  defp cursor(value) when value in [nil, ""], do: {:ok, 0}

  defp cursor(value) when is_binary(value) do
    with {:ok, "approvals:" <> n} <- Base.url_decode64(value, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(n) do
      {:ok, offset}
    else
      _bad -> Leads.invalid("cursor", "is not a cursor this API gave")
    end
  end

  defp cursor(_value), do: Leads.invalid("cursor", "is not a cursor this API gave")
end
