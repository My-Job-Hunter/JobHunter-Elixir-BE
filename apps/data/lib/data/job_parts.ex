defmodule Data.JobParts do
  @moduledoc """
  A job's parts (AQ-03 §5.1, §5.2): its skills, snapshots, platform details,
  the merges that point at it and its dismissals; and the moves a merge
  makes (§8). Storage only; `Core.Jobs` decides.
  """

  import Ecto.Query, warn: false

  alias Data.Jobs.{Dismissal, IndeedDetails, Job, JobSkill, LinkedinDetails, Merge, Signal}
  alias Data.Jobs.{Snapshot, UpworkDetails, YcDetails}
  alias Data.Repo

  @person [person: :photo]
  @details %{
    linkedin: LinkedinDetails,
    upwork: UpworkDetails,
    indeed: IndeedDetails,
    yc_waas: YcDetails
  }

  # ── Skills ──────────────────────────────────────────────────────────────────

  @doc "The skills become exactly `rows` (`%{skill_id, is_required}`)."
  @spec put_skills(Job.t(), [map()]) :: :ok | {:error, Ecto.Changeset.t()}
  def put_skills(%Job{} = job, rows) do
    Repo.delete_all(from(s in JobSkill, where: s.job_id == ^job.id))

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      attrs = %{job_id: job.id, skill_id: row.skill_id, is_required: row.is_required}

      case %JobSkill{} |> JobSkill.changeset(attrs) |> Repo.insert() do
        {:ok, _link} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # ── Snapshots ───────────────────────────────────────────────────────────────

  @doc "Keeps the posting's text; the same text twice stays one snapshot."
  @spec add_snapshot(map()) :: {:ok, Snapshot.t() | :exists} | {:error, Ecto.Changeset.t()}
  def add_snapshot(attrs) do
    changeset = Snapshot.changeset(%Snapshot{}, attrs)

    # Asked first: the key is made here, not by the database, so an insert
    # that met the unique index would still answer with an id (AQ-05's
    # capture counts what was new).
    if changeset.valid? and kept?(changeset),
      do: {:ok, :exists},
      else:
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:job_id, :body_sha256])
  end

  defp kept?(changeset) do
    job_id = Ecto.Changeset.get_field(changeset, :job_id)
    sha = Ecto.Changeset.get_field(changeset, :body_sha256)
    Repo.exists?(from(s in Snapshot, where: s.job_id == ^job_id and s.body_sha256 == ^sha))
  end

  # ── Signals (AQ-05 §5.3) ────────────────────────────────────────────────────

  @doc "The job's newest signals row, or `nil`."
  @spec latest_signal(binary()) :: Signal.t() | nil
  def latest_signal(job_id) do
    from(s in Signal,
      where: s.job_id == ^job_id,
      order_by: [desc: s.observed_at, desc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "How many signals rows the job has."
  @spec signal_count(binary()) :: non_neg_integer()
  def signal_count(job_id),
    do: from(s in Signal, where: s.job_id == ^job_id) |> Repo.aggregate(:count)

  @spec add_signal(map()) :: {:ok, Signal.t()} | {:error, Ecto.Changeset.t()}
  def add_signal(attrs), do: %Signal{} |> Signal.changeset(attrs) |> Repo.insert()

  # ── Platform details ────────────────────────────────────────────────────────

  @doc "The details table of a source (§5.2), or `nil` for a source without one."
  @spec details_schema(atom()) :: module() | nil
  def details_schema(source), do: Map.get(@details, source)

  @doc "Every details table, by source."
  def details_schemas, do: @details

  @doc "The job's row in its source's details table, or `nil`."
  @spec get_details(Job.t()) :: struct() | nil
  def get_details(%Job{source: source, id: id}) do
    case details_schema(source) do
      nil -> nil
      schema -> Repo.get(schema, id)
    end
  end

  @doc "Writes the job's row in its source's table, making it on first write."
  @spec put_details(Job.t(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t() | :none}
  def put_details(%Job{} = job, attrs) do
    case details_schema(job.source) do
      nil ->
        {:error, :none}

      schema ->
        (Repo.get(schema, job.id) || struct(schema, job_id: job.id))
        |> schema.changeset(attrs)
        |> Repo.insert_or_update()
    end
  end

  # ── Merges ──────────────────────────────────────────────────────────────────

  @doc "The links merged into a job, oldest first, with who merged them."
  @spec merges_into(binary()) :: [Merge.t()]
  def merges_into(job_id) do
    from(m in Merge,
      where: m.into_job_id == ^job_id,
      order_by: [asc: m.merged_at, asc: m.id],
      preload: [merged_by_user: ^@person]
    )
    |> Repo.all()
  end

  @spec add_merge(map()) :: {:ok, Merge.t()} | {:error, Ecto.Changeset.t()}
  def add_merge(attrs), do: %Merge{} |> Merge.changeset(attrs) |> Repo.insert()

  @doc """
  §8's moves from the merged job to the survivor, before the merged job is
  deleted: earlier merges re-pointed, skills united (required wins),
  snapshots moved (one of each text), signals moved (AQ-05), platform
  details moved where the survivor has none, dismissals moved unless the
  survivor has one for that profile.
  """
  @spec move_parts(Job.t(), Job.t()) :: :ok
  def move_parts(%Job{id: from}, %Job{id: into}) do
    Repo.update_all(from(m in Merge, where: m.into_job_id == ^from), set: [into_job_id: into])

    for link <- Repo.all(from(s in JobSkill, where: s.job_id == ^from)) do
      Repo.insert!(
        %JobSkill{job_id: into, skill_id: link.skill_id, is_required: link.is_required},
        on_conflict:
          from(s in JobSkill, update: [set: [is_required: s.is_required or ^link.is_required]]),
        conflict_target: [:job_id, :skill_id]
      )
    end

    kept = from(s in Snapshot, where: s.job_id == ^into, select: s.body_sha256)

    Repo.delete_all(
      from(s in Snapshot, where: s.job_id == ^from and s.body_sha256 in subquery(kept))
    )

    Repo.update_all(from(s in Snapshot, where: s.job_id == ^from), set: [job_id: into])
    Repo.update_all(from(s in Signal, where: s.job_id == ^from), set: [job_id: into])

    for schema <- Map.values(@details), is_nil(Repo.get(schema, into)) do
      Repo.update_all(from(d in schema, where: d.job_id == ^from), set: [job_id: into])
    end

    theirs = from(d in Dismissal, where: d.job_id == ^into, select: d.profile_id)

    Repo.delete_all(
      from(d in Dismissal, where: d.job_id == ^from and d.profile_id in subquery(theirs))
    )

    Repo.update_all(from(d in Dismissal, where: d.job_id == ^from), set: [job_id: into])
    :ok
  end

  # ── Dismissals ──────────────────────────────────────────────────────────────

  @doc "The dismissals of a job's suggestions, with who dismissed them."
  @spec dismissals(binary()) :: [Dismissal.t()]
  def dismissals(job_id) do
    from(d in Dismissal, where: d.job_id == ^job_id, preload: [dismissed_by_user: ^@person])
    |> Repo.all()
  end

  @doc "The dismissals of many jobs, as `%{job_id => [profile_id]}`."
  @spec dismissed_profiles([binary()]) :: %{binary() => [binary()]}
  def dismissed_profiles([]), do: %{}

  def dismissed_profiles(job_ids) do
    from(d in Dismissal, where: d.job_id in ^job_ids, select: {d.job_id, d.profile_id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "The jobs dismissed for a profile."
  @spec dismissed_jobs(binary()) :: [binary()]
  def dismissed_jobs(profile_id) do
    from(d in Dismissal, where: d.profile_id == ^profile_id, select: d.job_id) |> Repo.all()
  end

  @spec get_dismissal(binary(), binary()) :: Dismissal.t() | nil
  def get_dismissal(job_id, profile_id),
    do: Repo.get_by(Dismissal, job_id: job_id, profile_id: profile_id)

  @doc "Dismisses for a profile, or rewrites the reason of the dismissal already there."
  @spec put_dismissal(map()) :: {:ok, Dismissal.t()} | {:error, Ecto.Changeset.t()}
  def put_dismissal(%{job_id: job_id, profile_id: profile_id} = attrs) do
    (get_dismissal(job_id, profile_id) || %Dismissal{})
    |> Dismissal.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec delete_dismissal(Dismissal.t()) :: {:ok, Dismissal.t()} | {:error, Ecto.Changeset.t()}
  def delete_dismissal(%Dismissal{} = dismissal), do: Repo.delete(dismissal)
end
