defmodule Core.Jobs.Sheet do
  @moduledoc """
  What a job looks like to the console (AQ-03 §7.1): the **row** of the
  list, the **sheet** (the row, every column of `jobs` by its name, and the
  parts), the **suggestion**. `ApiShared.JobsJSON` lists the fields; this
  module fills them, because what a person sees depends on who they are:
  the suggestions are the live profiles of the customers **the job's team**
  serves that the caller may read (AQ-03B §5.1), and `can` is
  `Core.Access`'s answer.
  """

  alias Core.Access
  alias Core.Companies
  alias Core.Jobs.Suggest
  alias Core.Leads.Sheet, as: LeadSheet
  alias Core.Tasks.Person
  alias Data.JobParts
  alias Data.Jobs, as: Store
  alias Data.Jobs.Job
  alias Data.Leads, as: LeadStore
  alias Data.Profiles
  alias Data.Scope

  @columns ~w(source_url canonical_key source_job_id origin last_seen_at is_reposted poster_name
              description_md description_html seniority category openings allowed_countries
              allowed_regions required_timezones min_overlap_hours overlap_from_time
              overlap_to_time onsite_locations is_relocation_offered visa visa_text duration
              hours_min hours_max start_on is_immediate_start comp_min_minor comp_max_minor
              comp_currency comp_period comp_source comp_text is_comp_undisclosed equity_min_bp
              equity_max_bp equity_kind apply_method apply_url valid_through_on closed_at
              close_reason last_activity_at)a

  @doc "The `jobs` columns the sheet adds to the row, by name (§7.1)."
  def columns, do: @columns

  # ── Who a job may suit ──────────────────────────────────────────────────────

  @doc """
  Whom a team's jobs are scored for: the live profiles of the customers
  `team_id` serves, that the caller may read.
  """
  @spec profiles(Scope.t(), binary()) :: [map()]
  def profiles(%Scope{} = scope, team_id) do
    scope
    |> Scope.organisation_id()
    |> Profiles.live_in_organisation()
    |> Enum.filter(
      &(team_id in &1.customer.team_ids and Access.can?(scope, :read, {:profile, &1}))
    )
  end

  @doc """
  The best live, undismissed suggestion of each job (≥ 70), as
  `%{job_id => %{profile, customer, score}}`; a job with none is absent.
  """
  @spec best([Job.t()], [map()], DateTime.t()) :: %{binary() => map()}
  def best(jobs, profiles, %DateTime{} = now) do
    dismissed = jobs |> Enum.map(& &1.id) |> JobParts.dismissed_profiles()

    for job <- jobs,
        best = best_for(job, profiles, Map.get(dismissed, job.id, []), now),
        into: %{},
        do: {job.id, best}
  end

  defp best_for(job, profiles, dismissed, now) do
    profiles
    |> Enum.reject(&(&1.id in dismissed))
    |> Enum.map(&{&1, Suggest.score(&1, job, now).score})
    |> Enum.filter(fn {_p, score} -> score >= Suggest.threshold() end)
    |> Enum.sort_by(fn {p, score} -> {-score, p.id} end)
    |> case do
      [{profile, score} | _rest] ->
        %{profile: profile_ref(profile), customer: customer_ref(profile.customer), score: score}

      [] ->
        nil
    end
  end

  @doc "Every profile's suggestion for `job`, best first, dismissed ones included."
  @spec suggestions(Job.t(), [map()], DateTime.t()) :: [map()]
  def suggestions(%Job{} = job, profiles, %DateTime{} = now) do
    dismissals = Map.new(JobParts.dismissals(job.id), &{&1.profile_id, &1})

    profiles
    |> Enum.map(fn profile ->
      %{score: score, parts: parts} = Suggest.score(profile, job, now)

      %{
        profile: profile_ref(profile),
        customer: customer_ref(profile.customer),
        score: score,
        parts: parts,
        dismissed: dismissal(Map.get(dismissals, profile.id))
      }
    end)
    |> Enum.sort_by(&{-&1.score, &1.profile.id})
  end

  defp dismissal(nil), do: nil

  defp dismissal(d),
    do: %{
      reason: d.reason,
      note: d.note,
      by: Person.view(d.dismissed_by_user),
      at: d.dismissed_at
    }

  defp profile_ref(profile), do: %{id: profile.id, title: profile.title}
  defp customer_ref(customer), do: %{id: customer.id, display_name: customer.display_name}

  # ── The row and the sheet ───────────────────────────────────────────────────

  @doc "The list's row (§7.1); `best` is the job's best suggestion or `nil`."
  @spec row(Job.t(), map() | nil) :: map()
  def row(%Job{} = job, best) do
    %{
      id: job.id,
      title: job.title,
      team: team_ref(job.team),
      company: company_ref(job.company),
      source: job.source,
      engagement: job.engagement,
      workplace: job.workplace,
      remote_scope: job.remote_scope,
      onsite_locations: job.onsite_locations || [],
      money: money(job),
      posted_on: job.posted_on,
      first_seen_at: job.first_seen_at,
      status: job.status,
      archived_at: job.archived_at,
      best_suggestion: best
    }
  end

  @doc "The money as one fact (QP3-9): an estimate is `source == platform_estimate`."
  @spec money(Job.t()) :: map()
  def money(%Job{} = job) do
    %{
      min_minor: job.comp_min_minor,
      max_minor: job.comp_max_minor,
      currency: job.comp_currency,
      period: job.comp_period,
      source: job.comp_source,
      is_estimate: job.comp_source == :platform_estimate,
      is_undisclosed: job.is_comp_undisclosed,
      text: job.comp_text
    }
  end

  defp team_ref(%{id: id, name: name}), do: %{id: id, name: name}
  defp team_ref(_none), do: nil

  defp company_ref(nil), do: nil
  defp company_ref(company), do: %{id: company.id, name: company.name}

  @doc "The job's sheet as `scope` sees it, at `now`."
  @spec sheet(Scope.t(), Job.t(), DateTime.t()) :: map()
  def sheet(%Scope{} = scope, %Job{} = job, %DateTime{} = now) do
    job = Store.sheet(job)
    profiles = profiles(scope, job.team_id)
    suggestions = suggestions(job, profiles, now)
    best = best_of(suggestions)

    job
    |> row(best)
    |> Map.merge(Map.new(@columns, &{&1, Map.fetch!(job, &1)}))
    |> Map.merge(%{
      company: Companies.view(scope, job.company),
      skills: skills(job),
      platform_details: details(job),
      snapshots: Enum.map(job.snapshots, &snapshot/1),
      merged_from: job.id |> JobParts.merges_into() |> Enum.map(&merged/1),
      suggestions:
        Enum.filter(suggestions, &(&1.score >= Suggest.threshold() or not is_nil(&1.dismissed))),
      created_by: Person.view(job.created_by_user),
      last_changed: last_changed(Store.last_change(job)),
      signals: signals(job),
      can: can(scope, job)
    })
    |> Map.merge(leads(scope, job))
  end

  # *Leads on this job* (AQ-04A §8.1): the rows the caller may see, most
  # recent activity first, and how many they may not.
  defp leads(scope, job) do
    {seen, hidden} =
      [job.id]
      |> LeadStore.for_jobs()
      |> Enum.split_with(&Access.can?(scope, :read, {:lead, Core.Leads.subject(&1)}))

    %{leads: Enum.map(seen, &LeadSheet.row/1), hidden_leads: length(hidden)}
  end

  defp best_of(suggestions) do
    case Enum.find(suggestions, &(is_nil(&1.dismissed) and &1.score >= Suggest.threshold())) do
      nil -> nil
      s -> %{profile: s.profile, customer: s.customer, score: s.score}
    end
  end

  # Required first, then by name.
  defp skills(job) do
    job.job_skills
    |> Enum.map(&%{id: &1.skill_id, name: &1.skill.name, is_required: &1.is_required})
    |> Enum.sort_by(&{not &1.is_required, String.downcase(&1.name)})
  end

  defp details(job) do
    case JobParts.get_details(job) do
      nil -> nil
      %schema{} = row -> Map.new(schema.fields(), &{&1, number(Map.fetch!(row, &1))})
    end
  end

  # Upwork's `client_rating` is numeric(3,2): a number on the wire, not a string.
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value), do: value

  defp snapshot(s) do
    %{
      id: s.id,
      captured_at: s.captured_at,
      origin: s.origin,
      content_type: s.content_type,
      by: Person.view(s.captured_by_user)
    }
  end

  defp merged(m),
    do: %{
      title: m.from_title,
      source_url: m.from_source_url,
      at: m.merged_at,
      by: Person.view(m.merged_by_user)
    }

  @signal ~w(observed_at applicant_count is_applicant_count_capped proposals_min proposals_max
             interviewing invites_sent unanswered_invites hires client_last_viewed_at)a

  @doc """
  The job's signals (AQ-05 §11.2): `{latest, count}` — the newest
  `job_signals` row as §11.3's `signal` (or `nil`) and how many rows.
  """
  @spec signals(Job.t()) :: map()
  def signals(%Job{id: id}) do
    %{latest: signal(JobParts.latest_signal(id)), count: JobParts.signal_count(id)}
  end

  defp signal(nil), do: nil
  defp signal(row), do: Map.take(row, @signal)

  defp last_changed(nil), do: nil
  defp last_changed(event), do: %{by: Person.view(event.actor_user), at: event.occurred_at}

  defp can(scope, job) do
    may = &Access.can?(scope, &1, {:job, job})

    %{
      edit: may.(:edit),
      close: may.(:close) and job.status != :closed,
      reopen: may.(:reopen) and job.status == :closed,
      merge: may.(:merge),
      archive: may.(:archive) and is_nil(job.archived_at),
      unarchive: may.(:unarchive) and not is_nil(job.archived_at),
      share: may.(:read)
    }
  end
end
