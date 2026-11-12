defmodule Core.Retention do
  @moduledoc """
  Retention, done (AQ-04B §7): the three sweeps the workers run hourly on
  the `retention` queue, and Settings › Retention's preview. **The rule is
  `Core.Retention.Policy`'s** (pure); each sweep reads the candidates for
  every organisation (with its own settings and zone), asks the policy,
  and writes each decision in its own transaction as the system — nobody
  is the actor, so nothing it writes is activity. **Each is idempotent**: a
  second run finds nothing to do (a warning is once per quiet spell, an
  archived lead is not archived again, a purged one is gone).

  | Sweep | Does |
  |---|---|
  | `warn/1` | `archive_warned` (system, staff) and `leads.archive_warned` to the owner, dedupe `lead:<id>:warn:<last_activity_at>` |
  | `archive/1` | each quiet lead: `archived_at`, `archive_reason: inactive`, an `archived` event, the audit row, `leads.archived` to the owner (`lead:<id>:archived:<archived_at>`); then each job with no unarchived lead, itself quiet: archived, audited |
  | `purge/1` | each lead archived long enough: **a `lead_fingerprints` row first**, then the delete (its events, notes, labels, share links and notifications cascade; its tasks are unlinked; AQ-06 §10: its meetings and their attendees, its `lead_contacts` and its conversation links cascade, and **the conversations only it held** go with their messages and files, the bytes through `Core.Storage` after commit — a conversation another live lead holds stays, losing only the link; contacts are never purged; AQ-07 §10: its approvals, with their versions, slots, decisions and comments, and their files bytes and all — a profile's approvals stay); then each archived job with no lead left: deleted with its parts |

  `run_all/1` is `POST /dev/sweeps`: the follow-up scan and the three
  sweeps, in that order, saying what each did.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Leads
  alias Core.Leads.{FollowUp, Ledger, Moves, Signals, Words}
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Retention.Policy
  alias Core.Tasks.Write
  alias Data.Conversations
  alias Data.Jobs, as: JobStore
  alias Data.Retention, as: Store
  alias Data.Scope
  alias Data.Teams

  @day 86_400
  @horizon_days 14

  @doc "The follow-up scan and the three sweeps, in order: `[{name, what it did}]`."
  @spec run_all(DateTime.t()) :: [{String.t(), map()}]
  def run_all(%DateTime{} = now) do
    [
      {"follow_up_scan", FollowUp.scan(now)},
      {"warn_sweep", warn(now)},
      {"archive_sweep", archive(now)},
      {"purge_sweep", purge(now)}
    ]
  end

  # ── Warn ────────────────────────────────────────────────────────────────────

  @doc "The day-83 warning, every organisation. Answers `%{warned}`."
  @spec warn(DateTime.t()) :: map()
  def warn(%DateTime{} = now) do
    each_organisation(%{warned: 0}, fn org, settings, zone ->
      cutoff = ago(now, settings.inactivity_days - settings.warning_days)
      leads = Store.quiet_leads(org.id, cutoff)
      warned = Store.warned_at(Enum.map(leads, & &1.id))

      n =
        Enum.count(leads, fn lead ->
          Policy.lead_action(lead, warned[lead.id], settings, now, zone) == :warn and
            warn_one(Scope.system(org), lead, settings, now, zone)
        end)

      %{warned: n}
    end)
  end

  defp warn_one(scope, lead, settings, now, zone) do
    on = Policy.day(Policy.archive_at(lead, settings, zone), zone)

    {:ok, _lead} =
      Write.commit(fn ->
        _event = Ledger.record(scope, lead, :archive_warned, %{to_label: day_words(on)}, now)

        told =
          tell(scope, lead, "leads.archive_warned",
            title:
              "#{Words.job(lead.job)} (#{lead.profile.title}) archives on #{day_words(on)}. " <>
                "Open it or pin it to keep it.",
            dedupe: "lead:#{lead.id}:warn:#{DateTime.to_iso8601(lead.last_activity_at)}"
          )

        {:ok, lead, [told, Realtime.lead_events("lead_updated", lead)]}
      end)

    true
  end

  # ── Archive ─────────────────────────────────────────────────────────────────

  @doc "Quiet leads, then quiet jobs with no live lead, every organisation. Answers `%{leads, jobs}`."
  @spec archive(DateTime.t()) :: map()
  def archive(%DateTime{} = now) do
    each_organisation(%{leads: 0, jobs: 0}, fn org, settings, zone ->
      scope = Scope.system(org)
      leads = Store.quiet_leads(org.id, ago(now, settings.inactivity_days))

      archived =
        Enum.count(leads, fn lead ->
          Policy.lead_action(lead, nil, settings, now, zone) == :archive and
            archive_lead(scope, lead, settings, now)
        end)

      jobs =
        org.id
        |> Store.quiet_jobs(ago(now, settings.inactivity_days))
        |> Enum.count(fn job ->
          {live, all} = Store.lead_counts(job.id)

          Policy.job_action(job, live, all, settings, now) == :archive and
            archive_job(scope, job, now)
        end)

      %{leads: archived, jobs: jobs}
    end)
  end

  defp archive_lead(scope, lead, settings, now) do
    attrs = %{archived_at: now, archive_reason: :inactive, archived_by_user_id: nil}

    {:ok, _lead} =
      Write.commit(fn ->
        Moves.change(scope, lead, attrs, "archived", now, fn moved ->
          _event = Ledger.record(scope, moved, :archived, %{to_label: "Archived"}, now)

          told =
            tell(scope, moved, "leads.archived",
              title:
                "#{Words.job(moved.job)} was archived after #{settings.inactivity_days} quiet days.",
              dedupe: "lead:#{moved.id}:archived:#{DateTime.to_iso8601(now)}"
            )

          {[told], "lead_moved"}
        end)
      end)

    true
  end

  defp archive_job(scope, job, now) do
    {:ok, _job} =
      Write.commit(fn ->
        {:ok, updated} = JobStore.archive(job, now, nil)

        {:ok, _audit} =
          Audit.record(scope, "archived", updated,
            before: job_snapshot(job),
            after: job_snapshot(updated),
            now: now
          )

        {:ok, updated}
      end)

    true
  end

  # ── Purge ───────────────────────────────────────────────────────────────────

  @doc "Leads archived long enough (a fingerprint first), then bare archived jobs. Answers `%{leads, jobs}`."
  @spec purge(DateTime.t()) :: map()
  def purge(%DateTime{} = now) do
    each_organisation(%{leads: 0, jobs: 0}, fn org, settings, zone ->
      scope = Scope.system(org)
      leads = Store.archived_leads(org.id, ago(now, settings.purge_after_days))

      purged =
        Enum.count(leads, fn lead ->
          Policy.lead_action(lead, nil, settings, now, zone) == :purge and
            purge_lead(scope, lead, now, zone)
        end)

      jobs =
        org.id
        |> Store.bare_archived_jobs(ago(now, settings.purge_after_days))
        |> Enum.count(fn job ->
          Policy.job_action(job, 0, 0, settings, now) == :purge and purge_job(scope, job, now)
        end)

      %{leads: purged, jobs: jobs}
    end)
  end

  defp purge_lead(scope, lead, now, zone) do
    {:ok, files} =
      Write.commit(fn ->
        {:ok, _fingerprint} = Store.add_fingerprint(fingerprint(lead, now, zone))
        sole = Conversations.held_only_by(lead.id)
        # AQ-07 §10: its approvals go with it (versions, files, slots,
        # decisions, comments cascade); their files nothing else holds too.
        files = Conversations.media_of(sole) ++ Data.Approvals.media_held_only_by_lead(lead.id)
        _gone = Conversations.delete_all(sole)
        {:ok, deleted} = Store.delete_lead(lead)
        Enum.each(files, &({:ok, _row} = Data.Files.delete_for_system(&1)))

        {:ok, _audit} =
          Audit.record(scope, "purged", deleted,
            before: Map.put(Leads.snapshot(lead), "conversations_purged", length(sole)),
            now: now
          )

        {:ok, files, [Realtime.lead_events("lead_moved", lead)]}
      end)

    # The bytes only once the rows are gone for good.
    Enum.each(files, &(:ok = Core.Storage.delete(&1.storage_key)))
    true
  end

  @doc false
  # The tombstone (§5.2): what the guard must never forget, and nothing a
  # person wrote.
  def fingerprint(lead, now, zone) do
    stages = lead.pipeline_version.stages
    kind = &engine_kind/1

    reached =
      for e <- Store.all_events(lead.id),
          e.kind in [:applied, :stage_moved],
          stage = Enum.find(stages, &(&1.name == e.to_label)),
          do: kind.(stage)

    current = if lead.stage, do: [kind.(lead.stage)], else: []

    %{
      organisation_id: lead.organisation_id,
      team_id: lead.job.team_id,
      canonical_key: lead.job.canonical_key,
      profile_id: lead.profile_id,
      customer_id: lead.profile.customer_id,
      applied_on: lead.applied_at && Policy.day(lead.applied_at, zone),
      stage_kinds: (reached ++ current) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      outcome: lead.outcome,
      purged_at: now
    }
  end

  defp engine_kind(%{kind: :custom, anchor_kind: anchor}), do: anchor
  defp engine_kind(%{kind: kind}), do: kind

  defp purge_job(scope, job, now) do
    {:ok, _job} =
      Write.commit(fn ->
        {:ok, deleted} = JobStore.delete(job)

        {:ok, _audit} =
          Audit.record(scope, "purged", deleted, before: job_snapshot(job), now: now)

        {:ok, deleted}
      end)

    true
  end

  # ── The preview (§7.4) ──────────────────────────────────────────────────────

  @doc """
  `GET /retention/preview?team_id?`: what archives and purges in the next 14
  days, in the teams the caller may preview (the system admin every team, a
  team lead theirs; `team_id` narrows to one of them). Staff: not found.
  """
  @spec preview(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def preview(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, team_ids} <- teams(scope, Leads.blank(params["team_id"])) do
      org = scope.organisation
      settings = Signals.settings(org.id)
      zone = Signals.zone(org)
      horizon = DateTime.add(now, @horizon_days * @day, :second)

      archives =
        for lead <- Store.quiet_leads(org.id, ago(horizon, settings.inactivity_days), team_ids),
            at = Policy.archive_at(lead, settings, zone),
            Policy.reached?(at, horizon),
            do: %{
              lead: lead_row(lead),
              quiet_since: Policy.quiet_since(lead, zone),
              on: Policy.day(at, zone)
            }

      purges =
        for lead <-
              Store.archived_leads(org.id, ago(horizon, settings.purge_after_days), team_ids),
            do: %{
              lead: lead_row(lead),
              archived_at: lead.archived_at,
              on: Policy.purges_on(lead, settings, zone)
            }

      jobs =
        for(
          job <- Store.quiet_jobs(org.id, ago(horizon, settings.inactivity_days), team_ids),
          do: %{
            job: Core.Jobs.Sheet.row(job, nil),
            quiet_since: Policy.job_quiet_since(job),
            archives_on: Policy.day(Policy.job_archive_at(job, settings), zone),
            purges_on: nil
          }
        ) ++
          for(
            job <-
              Store.bare_archived_jobs(org.id, ago(horizon, settings.purge_after_days), team_ids),
            do: %{
              job: Core.Jobs.Sheet.row(job, nil),
              quiet_since: Policy.job_quiet_since(job),
              archives_on: nil,
              purges_on: Policy.day(Policy.job_purge_at(job, settings), zone)
            }
          )

      {:ok, %{archives: archives, purges: purges, jobs: jobs}}
    end
  end

  defp teams(scope, nil) do
    cond do
      Scope.admin?(scope) -> {:ok, nil}
      Scope.customer?(scope) -> {:error, :not_found}
      true -> led(scope)
    end
  end

  defp teams(scope, team_id) do
    with %{} = team <- Teams.get(Scope.organisation_id(scope), team_id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :preview, {:retention, %{team_id: team.id}}),
         do: {:ok, [team.id]}
  end

  defp led(scope) do
    case for {id, :lead} <- scope.roles.teams, do: id do
      [] -> {:error, :not_found}
      ids -> {:ok, ids}
    end
  end

  # A lead row (P4a §8.3) with the job and team it is on.
  defp lead_row(lead) do
    lead
    |> Leads.Sheet.row()
    |> Map.merge(%{
      job: %{
        id: lead.job.id,
        title: lead.job.title,
        company: lead.job.company && %{id: lead.job.company.id, name: lead.job.company.name}
      },
      team: %{id: lead.job.team.id, name: lead.job.team.name}
    })
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp each_organisation(zero, fun) do
    Enum.reduce(Store.list_organisations_for_system(), zero, fn org, acc ->
      result = fun.(org, Signals.settings(org.id), Signals.zone(org))
      Map.merge(acc, result, fn _key, a, b -> a + b end)
    end)
  end

  defp tell(scope, lead, kind, opts) do
    {:ok, row} =
      Notifications.ensure(scope, %{
        organisation_id: lead.organisation_id,
        user_id: lead.owner_user_id,
        notification_kind_key: kind,
        lead_id: lead.id,
        title: opts[:title],
        body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
        link_path: "/leads/#{lead.id}",
        dedupe_key: opts[:dedupe]
      })

    if row.is_new,
      do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end

  defp day_words(%Date{} = day), do: Calendar.strftime(day, "%-d %b")

  defp ago(now, days), do: DateTime.add(now, -days * @day, :second)

  defp job_snapshot(job), do: Audit.snapshot(job, ~w(team_id status archived_at)a)
end
