defmodule Core.Leads.FollowUp do
  @moduledoc """
  Follow-ups that happen (AQ-04B §6.2): ***Log follow-up*** and the hourly
  scan. The rule is `Core.Leads.FollowUps` (pure); nothing is stored but
  the ledger rows.

  - **`log/4`** (`POST /leads/:id/follow-up {from, note?}`): whoever may
    change the lead, while it waits on an answer (In progress at an
    `applied` or `seen` stage) and has a follow-up left to log. It writes
    `follow_up_logged` — a person's event, the customer's to read, so
    activity — with `to_label` "1 of 2" and the note as typed ("What did
    you send?"). `from` is the `{state, stage}` the client saw (409
    `lead_moved`).
  - **`scan/1`** (`Core.Workers.LeadFollowUpScan`, hourly): for every lead
    whose follow-up is due, one `leads.follow_up_due` to the owner
    (dedupe `lead:<id>:follow_up:<n>`) and one `follow_up_due` event
    (system, staff; not activity) per follow-up owed. Run twice, it adds
    nothing.
  """

  alias Core.Leads
  alias Core.Leads.{Act, FollowUps, Ledger, Next, Signals, Words}
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Leads, as: Store
  alias Data.Retention
  alias Data.Scope

  @doc "`POST /leads/:id/follow-up {from, note?}`. Answers the sheet."
  @spec log(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def log(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :follow_up, id),
         :ok <- Act.at(lead, params["from"]),
         :ok <- waiting(lead),
         {:ok, state} <- left(lead, now) do
      note = params["note"] |> Leads.blank() |> then(&(&1 && String.slice(&1, 0, 2000)))
      label = "#{state.count + 1} of #{state.of}"
      Leads.answer(scope, Write.commit(fn -> logged(scope, lead, label, note, now) end), now)
    end
  end

  # A follow-up left to log.
  defp left(lead, now) do
    settings = Signals.settings(lead.organisation_id)
    events = Map.get(Store.signal_events([lead.id]), lead.id, [])
    state = FollowUps.assess(lead, events, settings, now)

    if state.count >= state.of,
      do: Leads.invalid("from", "has all #{state.of} follow-ups logged"),
      else: {:ok, state}
  end

  defp logged(scope, lead, label, note, now) do
    _event = Ledger.record(scope, lead, :follow_up_logged, %{to_label: label, note: note}, now)
    {:ok, lead, [Realtime.lead_events("lead_updated", lead)]}
  end

  defp waiting(lead) do
    if FollowUps.waiting?(lead),
      do: :ok,
      else:
        Leads.invalid(
          "state",
          "can't log a follow-up on a lead that is #{Words.place(lead.state, lead.stage && lead.stage.name, lead.outcome)}"
        )
  end

  # ── The scan ────────────────────────────────────────────────────────────────

  @doc """
  The hourly scan at `now`, every organisation: answers `%{due, notified,
  events}` — how many leads were due, how many notifications and ledger
  rows it wrote this time.
  """
  @spec scan(DateTime.t()) :: map()
  def scan(%DateTime{} = now) do
    Retention.list_organisations_for_system()
    |> Enum.map(&scan_organisation(&1, now))
    |> Enum.reduce(%{due: 0, notified: 0, events: 0}, fn a, b ->
      Map.merge(a, b, fn _k, x, y -> x + y end)
    end)
  end

  defp scan_organisation(organisation, now) do
    scope = Scope.system(organisation)
    leads = Store.in_progress_for_system(organisation.id)
    ctx = Signals.context(organisation, leads, now)

    leads
    |> Enum.map(&{&1, Signals.follow_up(ctx, &1)})
    |> Enum.filter(fn {_lead, state} -> state.state == :due end)
    |> Enum.map(fn {lead, state} -> flag(scope, ctx, lead, state, now) end)
    |> Enum.reduce(%{due: 0, notified: 0, events: 0}, fn {n, e}, acc ->
      %{due: acc.due + 1, notified: acc.notified + n, events: acc.events + e}
    end)
  end

  # One follow-up owed: the event once (none since it fell due), the
  # notification once (by its key).
  defp flag(scope, ctx, lead, state, now) do
    events = Map.get(ctx.events, lead.id, [])

    already? =
      Enum.any?(
        events,
        &(&1.kind == :follow_up_due and DateTime.compare(&1.occurred_at, state.since) != :lt)
      )

    {:ok, counts} =
      Write.commit(fn ->
        written =
          if already? do
            0
          else
            _event =
              Ledger.record(
                scope,
                lead,
                :follow_up_due,
                %{to_label: "#{Next.ordinal(state.number)} of #{state.of}"},
                now
              )

            1
          end

        {:ok, row} =
          Notifications.ensure(scope, %{
            organisation_id: lead.organisation_id,
            user_id: lead.owner_user_id,
            notification_kind_key: "leads.follow_up_due",
            lead_id: lead.id,
            title:
              "Follow up on #{Words.job(lead.job)}: the #{Next.ordinal(state.number)} of #{state.of}",
            body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
            link_path: "/leads/#{lead.id}",
            dedupe_key: "lead:#{lead.id}:follow_up:#{state.number}"
          })

        told =
          if row.is_new,
            do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
            else: []

        lead_events = if written == 1, do: Realtime.lead_events("lead_updated", lead), else: []
        {:ok, {if(row.is_new, do: 1, else: 0), written}, [told, lead_events]}
      end)

    counts
  end
end
