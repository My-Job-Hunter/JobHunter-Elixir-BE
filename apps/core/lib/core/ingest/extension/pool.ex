defmodule Core.Ingest.Extension.Pool do
  @moduledoc """
  **A job already in the team's pool, seen again** (AQ-05 §10.2, QP5-13):
  by a capture (`POST /ext/v1/jobs/capture`), a *Save* or an *I applied*.
  In one transaction:

  - its blank fields are filled — **a field with a value is never
    overwritten**, a person's edit wins — by P3's merge fill
    (`Core.Jobs.Act.fill/2`: a money group whole or not at all), with the
    description, the company and the skills;
  - its platform details are refreshed: they are the platform's facts;
  - a snapshot of kind `fields` when the fields differ, a signals row when
    a fact differs (`Core.Jobs.Capture`);
  - `last_seen_at` and the job's `last_activity_at` move, and the fill is
    audited as P3's edit is.

  **At `peer_jobs: view` only *last seen* and the signals move.** A job the
  caller may not see (a teammate's at `hidden`) is never touched. Also the
  readings every extension write shares: the page's link, its fields, and
  the fields normalised for the organisation.
  """

  alias Core.Access
  alias Core.Companies
  alias Core.Ingest.Extension.Normalize
  alias Core.Jobs
  alias Core.Jobs.Act, as: JobAct
  alias Core.Jobs.{Capture, Check}
  alias Core.Jobs.Sheet, as: JobSheet
  alias Core.Leads
  alias Core.Tasks
  alias Data.JobParts
  alias Data.Jobs, as: JobStore
  alias Data.Jobs.Job
  alias Data.Repo
  alias Data.Scope
  alias Data.Skills
  alias Utils.JobKey

  @money ~w(comp_min_minor comp_max_minor comp_currency comp_period comp_source comp_text)a

  @doc """
  `POST /ext/v1/jobs/capture {team_id, url, fields}`: refreshes a job
  already in the team's pool, for whoever sees it. A key not in the pool
  answers `%{state: "not_in_pool"}` and writes nothing; a pool job the
  caller may not see, `%{state: "hidden"}`, nothing written. Else
  `%{state: "refreshed", job, filled, signals, unmatched_skills}`.
  """
  @spec capture(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def capture(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, link} <- link(params["url"]),
         {:ok, fields} <- fields(params) do
      case job(scope, team, link) do
        :none -> {:ok, %{state: "not_in_pool"}}
        {:hidden, _job} -> {:ok, %{state: "hidden"}}
        {:job, job} -> refreshed(scope, job, normalize(scope, fields, job.source, now), now)
      end
    end
  end

  defp refreshed(scope, job, norm, now) do
    with {:ok, {job, filled}} <- refresh(scope, job, norm, now) do
      {:ok,
       %{
         state: "refreshed",
         job: JobSheet.row(job, nil),
         filled: filled,
         signals: JobSheet.signals(job),
         unmatched_skills: norm.unmatched_skills
       }}
    end
  end

  @doc """
  The team's job for a link's key (a merged key's survivor), as the caller
  may know it: `{:job, job}`, `{:hidden, job}` or `:none`.
  """
  @spec job(Scope.t(), map(), map()) :: {:job, Job.t()} | {:hidden, Job.t()} | :none
  def job(%Scope{} = scope, team, link) do
    case Check.existing(team.id, link.key) do
      :none -> :none
      {:job, job} -> visible(scope, job)
      {:merged, job, _merge} -> visible(scope, job)
    end
  end

  defp visible(scope, job) do
    if Access.can?(scope, :read, {:job, job}), do: {:job, job}, else: {:hidden, job}
  end

  @doc """
  §10.2 in one transaction: what the caller may write of a capture on a
  pool job they see. Answers `{:ok, {job, filled}}`, the job fresh and the
  fields filled.
  """
  @spec refresh(Scope.t(), Job.t(), map(), DateTime.t()) :: {:ok, {Job.t(), [String.t()]}}
  def refresh(%Scope{} = scope, %Job{} = job, norm, %DateTime{} = now) do
    edit? = Access.can?(scope, :edit, {:job, job})

    Repo.transaction(fn ->
      before = if edit?, do: Jobs.audited(job)
      filled = if edit?, do: fill(scope, job, norm, now), else: []
      if edit?, do: refresh_details(job, norm.details)

      {:ok, _kept} = Capture.write(scope, job, kept(norm), now, snapshot: edit?)

      :ok = JobStore.seen(job, now, activity: edit?)
      if edit?, do: Jobs.record_changes(scope, job, before, Jobs.audited(job), now)
      {JobStore.reload(job), filled}
    end)
  end

  defp fill(scope, job, norm, now) do
    blanks =
      Job
      |> struct(columns(norm.job))
      |> JobAct.fill(job)
      |> put_if(is_nil(job.description_html) and norm.description_html, :description_html, fn ->
        norm.description_html
      end)
      |> put_if(is_nil(job.company_id) and norm.company, :company_id, fn ->
        Companies.find_or_insert(scope, norm.company, now).id
      end)

    filled = write_fill(job, blanks)

    if job.job_skills == [] and norm.skills != [] do
      :ok = JobParts.put_skills(job, Enum.map(norm.skills, &%{skill_id: &1, is_required: true}))
      Enum.sort(["skills" | filled])
    else
      filled
    end
  end

  defp put_if(map, condition, key, value) do
    if condition, do: Map.put(map, key, value.()), else: map
  end

  defp write_fill(job, blanks) do
    case valid_blanks(job, blanks) do
      kept when kept == %{} ->
        []

      kept ->
        {:ok, _job} = JobStore.fill(job, kept)
        kept |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    end
  end

  # What the job's own changeset accepts of the blanks, asked before the
  # write: a refused field (and its money group) is dropped, never sent to
  # a constraint that would end the transaction.
  defp valid_blanks(job, blanks) do
    case Job.changeset(job, blanks) do
      %{valid?: true} ->
        blanks

      %{errors: errors} ->
        refused = Keyword.keys(errors)
        kept = Map.drop(blanks, refused ++ money_keys(refused))
        if map_size(kept) < map_size(blanks), do: valid_blanks(job, kept), else: %{}
    end
  end

  defp money_keys(refused), do: if(Enum.any?(refused, &(&1 in @money)), do: @money, else: [])

  # The platform's facts refresh: what the page showed replaces what was
  # there (a fact it did not show stays). A value the table refuses is
  # dropped with its row's write, never the capture.
  defp refresh_details(_job, details) when details == %{}, do: :ok

  defp refresh_details(job, details) do
    with schema when not is_nil(schema) <- JobParts.details_schema(job.source),
         %{valid?: true} <- schema.changeset(struct(schema, job_id: job.id), details),
         {:ok, _job} <- Jobs.put_details(job, details) do
      :ok
    else
      _refused -> :ok
    end
  end

  defp columns(body) do
    editable = Map.new(Job.editable_fields(), &{to_string(&1), &1})
    for {k, v} <- body, Map.has_key?(editable, k), into: %{}, do: {Map.fetch!(editable, k), v}
  end

  # ── What every extension write reads ────────────────────────────────────────

  @doc "What `Core.Jobs.insert_new/5` and `Core.Jobs.Capture` keep of a capture."
  @spec kept(map()) :: map()
  def kept(norm),
    do: %{snapshot: norm.snapshot, signal: norm.signal, description_html: norm.description_html}

  @doc "The fields, normalised for the organisation: its zone, its skills, the link's site."
  @spec normalize(Scope.t(), map(), atom(), DateTime.t()) :: map()
  def normalize(%Scope{} = scope, fields, source, %DateTime{} = now) do
    Normalize.run(fields, %{
      site: if(source == :upwork, do: :upwork, else: :linkedin),
      now: now,
      zone: Tasks.zone(scope),
      skills: Enum.map(Skills.list(Scope.organisation_id(scope)), &%{id: &1.id, name: &1.name})
    })
  end

  @doc "The body's `fields`: an object, required."
  @spec fields(map()) :: {:ok, map()} | {:error, term()}
  def fields(%{"fields" => %{} = fields}), do: {:ok, fields}
  def fields(%{"fields" => nil}), do: {:error, {:missing, [:fields]}}
  def fields(%{"fields" => _other}), do: Leads.invalid("fields", "is an object")
  def fields(_params), do: {:error, {:missing, [:fields]}}

  @doc "The page's link: a job posting's (`Utils.JobKey`), required."
  @spec link(term()) :: {:ok, map()} | {:error, term()}
  def link(url) do
    case JobKey.parse(url) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :not_a_link} when is_nil(url) -> {:error, {:missing, [:url]}}
      {:error, :not_a_job} -> Leads.invalid("url", "is not a job posting")
      {:error, :not_a_link} -> Leads.invalid("url", "is not a job link")
    end
  end
end
