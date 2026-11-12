defmodule Core.Jobs do
  @moduledoc """
  The job pool (AQ-03 P3.1): a job read, checked, added, edited, and its
  platform details. The list is `Core.Jobs.Pool`, the check
  `Core.Jobs.Check`, the verbs (close, reopen, archive, unarchive, merge,
  dismissals) `Core.Jobs.Act`, the score `Core.Jobs.Suggest`, the shapes
  `Core.Jobs.Sheet`.

  Every job is in one team's pool (AQ-03B §4): the list, the check and a
  new job name the team (`team_id`, required: 422 without it, 404 for a team
  the caller is not in unless an admin), and the key is unique per team.
  Every function takes a `%Data.Scope{}` first and asks `Core.Access`
  (`{:job, job}`, decided by `Core.Access.Jobs`, which reads the team's
  `peer_jobs`); a job the caller may not see is `:not_found`. Every write is one transaction holding the change
  and its audit row (QP3-11: a job's history is its audit rows). No
  realtime in P3 (QP3-15).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Companies
  alias Core.Jobs.{Capture, Check, Sheet}
  alias Data.JobParts
  alias Data.Jobs, as: Store
  alias Data.Jobs.{Job, UpworkDetails}
  alias Data.Repo
  alias Data.Scope
  alias Data.Skills
  alias Data.Teams
  alias Utils.JobKey

  @created ~w(team_id title source canonical_key company_id status)a
  @seniority_of %{entry: :entry, intermediate: :associate, expert: :mid_senior}

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The job behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Job.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Job{} = job <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:job, job}),
         do: {:ok, job}
  end

  @doc "`GET /jobs/:id`: the sheet."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, job} <- fetch(scope, :read, id), do: {:ok, Sheet.sheet(scope, job, now)}
  end

  @doc "The sheet of a job just written."
  @spec answer(Scope.t(), {:ok, Job.t()} | {:error, term()}, DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def answer(%Scope{} = scope, {:ok, %Job{} = job}, %DateTime{} = now),
    do: {:ok, Sheet.sheet(scope, Store.reload(job), now)}

  def answer(_scope, {:error, _reason} = error, _now), do: error

  @doc """
  `GET /jobs/:id/suggestions`: the live profiles of the customers the job's
  team serves that the caller may read, best first (AQ-03B §5.1).
  """
  @spec suggestions(Scope.t(), term(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def suggestions(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, job} <- fetch(scope, :read, id),
         do: {:ok, Sheet.suggestions(job, Sheet.profiles(scope, job.team_id), now)}
  end

  @doc """
  The team a list, a check or a new job names: `team_id` is required (422
  without it), and must be a live team of the organisation the caller is in
  (any, for an admin), else it is not found.
  """
  @spec team(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def team(%Scope{} = scope, params) do
    case Utils.presence(to_string(params["team_id"] || "")) do
      nil ->
        {:error, {:invalid, %{"team_id" => ["is required"]}}}

      id ->
        with %{archived_at: nil} = team <- Teams.get(Scope.organisation_id(scope), id),
             :ok <- Access.why_not(scope, :read, {:job, %{team_id: team.id}}) do
          {:ok, team}
        else
          _other -> {:error, :not_found}
        end
    end
  end

  # ── Create ──────────────────────────────────────────────────────────────────

  @doc """
  `POST /jobs {team_id, url, …the sheet's columns…, company_id | company:
  {name, website_url?}, skills: [{skill_id, is_required}], platform_details?,
  snapshot_text?}`: `origin: manual`, in that team's pool. The check runs
  again inside the transaction: a link already in the team's pool — or merged into a job — is
  `{:error, {:job_exists, job}}`, and so is one that lands between the
  check and the insert (the unique key catches it). Answers the sheet.
  """
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with :ok <- Access.why_not(scope, :create, {:job, %{}}),
         {:ok, team} <- team(scope, params),
         :ok <- Access.why_not(scope, :create, {:job, %{team_id: team.id}}) do
      answer(scope, insert_new(scope, team, params, now), now)
    end
  end

  @doc """
  A new job in `team`'s pool from `POST /jobs`'s body, the check re-run in
  its transaction (`{:error, {:job_exists, job | :hidden}}`). Answers the
  job, not the sheet: `POST /leads` with a `job` body (AQ-04A §8.1, QP4a-18)
  calls it inside its own transaction, after its own access check.

  `opts[:capture]` is the extension's (AQ-05 §10.1): the job's `origin` is
  `extension`, its `description_html` the sanitised page's, and
  `Core.Jobs.Capture` keeps the fields as a snapshot and the signals.
  """
  @spec insert_new(Scope.t(), map(), map(), DateTime.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def insert_new(%Scope{} = scope, team, params, %DateTime{} = now, opts \\ []) do
    params = stringify(params)
    capture = opts[:capture]

    with {:ok, link} <- link(params["url"]),
         {:ok, skills} <- skills(scope, params) do
      Repo.transaction(fn -> insert(scope, team, {params, capture}, link, skills, now) end)
      |> case do
        {:error, :key_taken} -> exists(scope, existing_job(team.id, link.key))
        {:error, {:job_exists, job}} -> exists(scope, job)
        result -> result
      end
    end
  end

  defp insert(scope, team, {params, capture}, link, skills, now) do
    org_id = Scope.organisation_id(scope)

    with :none <- Check.existing(team.id, link.key),
         {:ok, company_id} <- company(scope, params, :none, now),
         attrs =
           params
           |> editable()
           |> put_company(company_id)
           |> Map.merge(%{
             "organisation_id" => org_id,
             "team_id" => team.id,
             "source" => link.source,
             "source_url" => link.url,
             "canonical_key" => link.key,
             "source_job_id" => link.source_job_id,
             "origin" => if(capture, do: "extension", else: "manual"),
             "description_html" => capture && capture[:description_html],
             "first_seen_at" => now,
             "last_seen_at" => now,
             "last_activity_at" => now,
             "created_by_user_id" => Scope.user_id(scope)
           }),
         {:ok, job} <- Store.create(attrs) |> key_taken(),
         :ok <- put_skills(job, skills),
         {:ok, job} <- put_details(job, params["platform_details"]),
         :ok <- snapshot(scope, job, params["snapshot_text"], now),
         {:ok, _kept} <- Capture.write(scope, job, capture, now) do
      {:ok, _event} =
        Audit.record(scope, "created", job, after: Audit.snapshot(job, @created), now: now)

      job
    else
      {:job, job} -> Repo.rollback({:job_exists, job})
      {:merged, job, _merge} -> Repo.rollback({:job_exists, job})
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A job the caller may not see (a teammate's, at `hidden`) is named to
  # nobody: the 409 says only that the team holds it (AQ-03B §5.1).
  defp exists(scope, job) do
    if job && Access.can?(scope, :read, {:job, job}),
      do: {:error, {:job_exists, job}},
      else: {:error, {:job_exists, :hidden}}
  end

  # The unique key met a row the check could not see yet: the race.
  defp key_taken({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    case errors[:url] do
      {_message, opts} ->
        if opts[:constraint] == :unique, do: {:error, :key_taken}, else: {:error, changeset}

      nil ->
        {:error, changeset}
    end
  end

  defp key_taken(ok), do: ok

  defp existing_job(team_id, key) do
    case Check.existing(team_id, key) do
      {:job, job} -> job
      {:merged, job, _merge} -> job
      :none -> nil
    end
  end

  defp link(url) do
    case JobKey.parse(url) do
      {:ok, parsed} -> {:ok, Map.put(parsed, :url, web_link(url))}
      {:error, :not_a_job} -> {:error, {:invalid, %{"url" => ["is not a job posting"]}}}
      {:error, :not_a_link} when is_nil(url) -> {:error, {:missing, [:url]}}
      {:error, :not_a_link} -> {:error, {:invalid, %{"url" => ["is not a job link"]}}}
    end
  end

  # The link as pasted, trimmed, with its scheme.
  defp web_link(url) do
    url = String.trim(url)
    if url =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, do: url, else: "https://" <> url
  end

  # ── Edit ────────────────────────────────────────────────────────────────────

  @doc """
  `PATCH /jobs/:id`: any column of the sheet but the link and the key, the
  company, `skills` (replacing the set) and `platform_details`. Audited with
  the before and after of what changed.
  """
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, job} <- fetch(scope, :edit, id),
         {:ok, skills} <- skills(scope, params) do
      answer(scope, Repo.transaction(fn -> save(scope, job, params, skills, now) end), now)
    end
  end

  defp save(scope, job, params, skills, now) do
    before = audited(job)

    with {:ok, company_id} <- company(scope, params, :keep, now),
         attrs =
           params |> editable() |> put_company(company_id) |> Map.put("last_activity_at", now),
         {:ok, updated} <- Store.update(job, attrs),
         :ok <- if(skills == :keep, do: :ok, else: put_skills(updated, skills)),
         {:ok, updated} <- put_details(updated, params["platform_details"]) do
      updated = Store.reload(updated)
      record_changes(scope, updated, before, audited(updated), now)
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "`PUT /jobs/:id/platform-details`: the row of the job's source's table (§5.2)."
  @spec put_platform_details(Scope.t(), term(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def put_platform_details(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, job} <- fetch(scope, :edit, id),
         :ok <- has_details(job) do
      answer(scope, Repo.transaction(fn -> save_details(scope, job, params, now) end), now)
    end
  end

  defp save_details(scope, job, params, now) do
    before = audited(job)

    case put_details(job, stringify(params)) do
      {:ok, updated} ->
        :ok = Store.touch(updated, now)
        record_changes(scope, updated, before, audited(updated), now)
        updated

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp has_details(job) do
    if JobParts.details_schema(job.source),
      do: :ok,
      else: {:error, {:invalid, %{"platform_details" => ["a #{job.source} job has none"]}}}
  end

  @doc false
  # The audit row of an edit: only what changed, before and after.
  def record_changes(scope, job, before, after_, now) do
    keys = for {k, v} <- after_, before[k] != v, do: k

    if keys != [] do
      {:ok, _event} =
        Audit.record(scope, "updated", job,
          before: Map.take(before, keys),
          after: Map.take(after_, keys),
          now: now
        )
    end

    :ok
  end

  @doc false
  # What the audit rows compare: the editable columns, the skills and the
  # platform details, JSON-safe.
  def audited(%Job{} = job) do
    job = Store.reload(job)

    job
    |> Audit.snapshot(Job.editable_fields())
    |> Map.put(
      "skills",
      job.job_skills
      |> Enum.map(&%{"skill_id" => &1.skill_id, "is_required" => &1.is_required})
      |> Enum.sort_by(& &1["skill_id"])
    )
    |> Map.put("platform_details", details_snapshot(JobParts.get_details(job)))
  end

  defp details_snapshot(nil), do: nil
  defp details_snapshot(%schema{} = row), do: Audit.snapshot(row, schema.fields())

  # ── The parts a write carries ───────────────────────────────────────────────

  # `company_id`, or `company: {name, website_url?}` found by its normalised
  # name or made; neither keeps the job's (`:keep`) or leaves it blank.
  defp company(scope, params, default, now) do
    case {Map.has_key?(params, "company_id"), params["company"]} do
      {true, %{}} ->
        {:error, {:invalid, %{"company" => ["give company_id or company, not both"]}}}

      {true, _none} ->
        company_by_id(scope, params["company_id"])

      {false, %{} = company} ->
        company_by_name(scope, company, now)

      {false, _none} ->
        {:ok, default}
    end
  end

  defp company_by_id(scope, id) do
    case Utils.presence(to_string(id || "")) do
      nil -> {:ok, nil}
      id -> known_company(scope, id)
    end
  end

  @doc false
  # A company found by its normalised name, or made (P3): what a capture's
  # `company_name` becomes too (AQ-05 §10.1).
  def company_by_name(scope, company, now) do
    if Utils.presence(company["name"] || company[:name]),
      do: {:ok, Companies.find_or_insert(scope, company, now).id},
      else: {:error, {:invalid, %{"company" => ["needs a name"]}}}
  end

  defp known_company(scope, id) do
    case Companies.fetch(scope, :read, id) do
      {:ok, company} ->
        {:ok, company.id}

      {:error, _not_found} ->
        {:error, {:invalid, %{"company_id" => ["is not a company of this organisation"]}}}
    end
  end

  defp put_company(attrs, :keep), do: attrs
  defp put_company(attrs, :none), do: attrs
  defp put_company(attrs, company_id), do: Map.put(attrs, "company_id", company_id)

  @doc false
  # `skills: [{skill_id, is_required}]`, every one a skill of the organisation.
  def skills(scope, %{"skills" => rows}) when is_list(rows) do
    org_id = Scope.organisation_id(scope)

    rows
    |> Enum.map(&stringify/1)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case Skills.get(org_id, row["skill_id"]) do
        %{id: id} ->
          {:cont,
           {:ok, [%{skill_id: id, is_required: row["is_required"] not in [false, "false"]} | acc]}}

        nil ->
          {:halt,
           {:error, {:invalid, %{"skills" => ["has a skill that is not in the vocabulary"]}}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq_by(& &1.skill_id)}
      error -> error
    end
  end

  def skills(_scope, %{"skills" => nil}), do: {:ok, :keep}

  def skills(_scope, %{"skills" => _other}),
    do: {:error, {:invalid, %{"skills" => ["is a list of {skill_id, is_required}"]}}}

  def skills(_scope, _params), do: {:ok, :keep}

  defp put_skills(_job, :keep), do: :ok
  defp put_skills(job, rows), do: JobParts.put_skills(job, rows)

  @doc false
  # The source's table, when it has one; ignored for a source without one.
  # Upwork's experience level becomes the job's seniority when it has none.
  # A capture of a pool job refreshes it through here too (AQ-05 §10.2).
  def put_details(job, attrs) when is_map(attrs) do
    case JobParts.put_details(job, attrs) do
      {:ok, %UpworkDetails{experience_level: level}}
      when not is_nil(level) and is_nil(job.seniority) ->
        Store.update(job, %{seniority: Map.fetch!(@seniority_of, level)})

      {:ok, _row} ->
        {:ok, job}

      {:error, :none} ->
        {:ok, job}

      {:error, _changeset} = error ->
        error
    end
  end

  def put_details(job, _none), do: {:ok, job}

  defp snapshot(scope, job, text, now) when is_binary(text) do
    case Utils.presence(text) do
      nil ->
        :ok

      body ->
        attrs = %{
          job_id: job.id,
          captured_at: now,
          captured_by_user_id: Scope.user_id(scope),
          origin: :manual,
          content_type: :text,
          body: body
        }

        case JobParts.add_snapshot(attrs) do
          {:ok, _snapshot} -> :ok
          error -> error
        end
    end
  end

  defp snapshot(_scope, _job, _text, _now), do: :ok

  defp editable(params), do: Map.take(params, Enum.map(Job.editable_fields(), &to_string/1))

  @doc false
  def stringify(params) when is_map(params),
    do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  def stringify(_params), do: %{}
end
