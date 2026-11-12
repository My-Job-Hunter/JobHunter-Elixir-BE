defmodule Core.Leads.Signals do
  @moduledoc """
  What a card, a Tracker row and the lead page add to a lead in P4b, read
  **once for a set of leads** (AQ-04B §6, §7.5, §9): *Next*, the follow-up
  badge, the quiet clock ("Archives in 23 days") and the labels. The rules
  are the pure `Core.Leads.Next`, `Core.Leads.FollowUps` and
  `Core.Retention.Policy`; this module gathers their inputs — the
  organisation's settings and zone, each lead's signal events, its open
  linked tasks, its labels, (AQ-06) its next meeting and (AQ-07) its pending
  approval due soonest — in a fixed number of reads, so a board of fifty
  cards is not fifty round trips.
  """

  alias Core.Leads.{FollowUps, Next}
  alias Core.Retention.Policy
  alias Data.Labels
  alias Data.Leads, as: Store
  alias Data.Organisations
  alias Data.Tasks, as: TaskStore

  @doc """
  The context for `leads` of `organisation` (a struct with `id` and
  `timezone`) at `now`.
  """
  @spec context(map(), [map()], DateTime.t()) :: map()
  def context(organisation, leads, %DateTime{} = now) do
    ids = Enum.map(leads, & &1.id)

    %{
      now: now,
      zone: zone(organisation),
      settings: settings(organisation.id),
      events: Store.signal_events(ids),
      tasks: TaskStore.open_for_leads(ids),
      labels: Labels.for_leads(ids),
      meetings: Data.Meetings.next_for_leads(ids, now),
      approvals: Data.Approvals.next_due_for_leads(ids)
    }
  end

  @doc "The organisation's timings, as the rules read them."
  @spec settings(binary()) :: map()
  def settings(organisation_id) do
    s = Organisations.get_settings(organisation_id)

    %{
      follow_up_gap_days: s.follow_up_gap_days,
      max_follow_ups: s.max_follow_ups,
      no_response_days: s.no_response_days,
      inactivity_days: s.inactivity_days,
      warning_days: s.warning_days,
      purge_after_days: s.purge_after_days
    }
  end

  @doc "The organisation's zone (UTC when it has none)."
  @spec zone(map()) :: String.t()
  def zone(%{timezone: zone}) when is_binary(zone), do: zone
  def zone(_organisation), do: "Etc/UTC"

  @doc """
  One lead's signals: `%{next, follow_up: {state, count, of}, quiet: {since,
  archives_on, warn}, labels: [{id, name}]}`.
  """
  @spec for_lead(map(), map()) :: map()
  def for_lead(ctx, lead) do
    follow_up = follow_up(ctx, lead)

    %{
      next:
        Next.of(
          Map.get(Map.get(ctx, :meetings, %{}), lead.id),
          Map.get(Map.get(ctx, :approvals, %{}), lead.id),
          Map.get(ctx.tasks, lead.id, []),
          follow_up,
          ctx.settings,
          ctx.now,
          ctx.zone
        ),
      follow_up: %{state: follow_up.state, count: follow_up.count, of: follow_up.of},
      quiet: Policy.quiet(lead, ctx.settings, ctx.now, ctx.zone),
      labels: Enum.map(Map.get(ctx.labels, lead.id, []), &%{id: &1.id, name: &1.name})
    }
  end

  @doc "`Core.Leads.FollowUps.assess/4` for a lead of the context."
  @spec follow_up(map(), map()) :: FollowUps.result()
  def follow_up(ctx, lead),
    do: FollowUps.assess(lead, Map.get(ctx.events, lead.id, []), ctx.settings, ctx.now)
end
