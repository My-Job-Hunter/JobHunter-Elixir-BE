defmodule Data.Jobs do
  @moduledoc """
  The job pool's rows (AQ-03 §5.1). Storage only: who may do what is
  `Core.Access`'s (`{:job, _}`), the check, merge and score are `Core.Jobs`'s.
  The list with its filters is `Data.JobList`; a job's parts (skills,
  snapshots, platform details, merges, dismissals) are `Data.JobParts`.

  Every job read here comes with its company and its skills (with their
  names), because the row, the check and the score all show them.
  """

  import Ecto.Query, warn: false

  alias Data.Audit.AuditEvent
  alias Data.Jobs.{Job, Merge}
  alias Data.Repo

  @person [person: :photo]
  @base [:company, :team, job_skills: :skill]
  @sheet [
    :team,
    company: [created_by_user: @person],
    job_skills: :skill,
    created_by_user: @person,
    snapshots: [captured_by_user: @person],
    dismissals: [dismissed_by_user: @person]
  ]

  @doc "What every job read carries."
  def base_preload, do: @base

  @doc "A job of the organisation; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Job.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Job |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load(@base)

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The job of a team's pool whose canonical key is `key`, or `nil` (AQ-03B: the key is per team)."
  @spec get_by_key(binary(), String.t()) :: Job.t() | nil
  def get_by_key(team_id, key) do
    Job |> Repo.get_by(team_id: team_id, canonical_key: key) |> load(@base)
  end

  @doc "The merge in a team's pool that kept `key`, with the job it now resolves to, or `nil` (QP3-8)."
  @spec merge_for_key(binary(), String.t()) :: Merge.t() | nil
  def merge_for_key(team_id, key) do
    from(m in Merge,
      where: m.team_id == ^team_id and m.from_canonical_key == ^key,
      preload: [into_job: ^@base]
    )
    |> Repo.one()
  end

  @doc "The job with everything its sheet shows."
  @spec sheet(Job.t()) :: Job.t()
  def sheet(%Job{} = job), do: Repo.preload(job, @sheet, force: true)

  @doc "Jobs by id, with what a row shows, in no particular order."
  @spec by_ids(binary(), [binary()]) :: [Job.t()]
  def by_ids(_organisation_id, []), do: []

  def by_ids(organisation_id, ids) do
    from(j in Job, where: j.organisation_id == ^organisation_id and j.id in ^ids, preload: ^@base)
    |> Repo.all()
  end

  @doc """
  The similar check's candidates (§6.3): live jobs of a team's pool of
  `company_ids` first seen from `since`, newest first. The title rule is
  `Utils.JobKey`'s.
  """
  @spec seen_since(binary(), [binary()], DateTime.t()) :: [Job.t()]
  def seen_since(_team_id, [], _since), do: []

  def seen_since(team_id, company_ids, %DateTime{} = since) do
    from(j in Job,
      where:
        j.team_id == ^team_id and j.company_id in ^company_ids and
          j.first_seen_at >= ^since and is_nil(j.archived_at),
      order_by: [desc: j.first_seen_at, desc: j.id],
      preload: ^@base
    )
    |> Repo.all()
  end

  @doc "The latest audit row about a job, with its actor: the sheet's *last changed*."
  @spec last_change(Job.t()) :: AuditEvent.t() | nil
  def last_change(%Job{} = job) do
    from(e in AuditEvent,
      where:
        e.organisation_id == ^job.organisation_id and e.subject_kind == "jobs" and
          e.subject_id == ^job.id,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: 1,
      preload: [actor_user: ^@person]
    )
    |> Repo.one()
  end

  @doc "Every audit row about a job, newest first, with its actor: its trail (AQ-03B §5.1)."
  @spec trail(Job.t()) :: [AuditEvent.t()]
  def trail(%Job{} = job) do
    from(e in AuditEvent,
      where:
        e.organisation_id == ^job.organisation_id and e.subject_kind == "jobs" and
          e.subject_id == ^job.id,
      order_by: [desc: e.occurred_at, desc: e.id],
      preload: [actor_user: ^@person]
    )
    |> Repo.all()
  end

  @doc "The job again, with its company and skills fresh."
  @spec reload(Job.t()) :: Job.t()
  def reload(%Job{} = job), do: Job |> Repo.get!(job.id) |> load(@base)

  defp load(nil, _preloads), do: nil
  defp load(job, preloads), do: Repo.preload(job, preloads, force: true)

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, job} <- %Job{} |> Job.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(job)}
  end

  @spec update(Job.t(), map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def update(%Job{} = job, attrs) do
    with {:ok, updated} <- job |> Job.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "Close or reopen: the status and its columns."
  @spec close(Job.t(), map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def close(%Job{} = job, attrs) do
    with {:ok, updated} <- job |> Job.close_changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @spec archive(Job.t(), DateTime.t() | nil, binary() | nil) :: {:ok, Job.t()}
  def archive(%Job{} = job, at, user_id) do
    {:ok, updated} = job |> Job.archive_changeset(at, user_id) |> Repo.update()
    {:ok, reload(updated)}
  end

  @doc "A merge's fill of the survivor's blanks."
  @spec fill(Job.t(), map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def fill(%Job{} = job, attrs) do
    with {:ok, updated} <- job |> Job.fill_changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "Touches `last_activity_at`."
  @spec touch(Job.t(), DateTime.t()) :: :ok
  def touch(%Job{} = job, %DateTime{} = at) do
    {1, _rows} =
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [last_activity_at: at])

    :ok
  end

  @doc """
  Seen again (AQ-05 §10.2, PLAN §6.8): `last_seen_at` moves, and with
  `activity: true` the job's `last_activity_at` too.
  """
  @spec seen(Job.t(), DateTime.t(), keyword()) :: :ok
  def seen(%Job{} = job, %DateTime{} = at, opts \\ []) do
    set =
      if Keyword.get(opts, :activity, false),
        do: [last_seen_at: at, last_activity_at: at],
        else: [last_seen_at: at]

    {1, _rows} = Repo.update_all(from(j in Job, where: j.id == ^job.id), set: set)
    :ok
  end

  @spec delete(Job.t()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Job{} = job), do: Repo.delete(job)
end
