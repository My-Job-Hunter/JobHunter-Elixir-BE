defmodule Data.Retention do
  @moduledoc """
  What the retention sweeps and the preview read and write (AQ-04B §7):
  the candidates, by a cutoff the caller computes from the settings (the
  rule itself is `Core.Retention.Policy`'s), the tombstones
  (`lead_fingerprints`), and the deletes. These are **system reads**: the
  sweeps act for nobody, across every team of an organisation; the preview
  narrows them to `team_ids`.
  """

  import Ecto.Query, warn: false

  alias Data.Jobs.Job
  alias Data.Leads
  alias Data.Leads.{Event, Fingerprint, Lead}
  alias Data.Organisations.Organisation
  alias Data.Repo

  @doc "Every organisation: the sweeps run each with its own settings and zone."
  @spec list_organisations_for_system() :: [Organisation.t()]
  def list_organisations_for_system,
    do: Repo.all(from(o in Organisation, order_by: o.inserted_at))

  # ── Leads ───────────────────────────────────────────────────────────────────

  @doc """
  Live, unpinned leads of the organisation quiet since `cutoff` or longer by
  `last_activity_at` (a superset: a hold's *until* day only makes a lead
  quieter later), with what a card shows. `team_ids` narrows (nil: all).
  """
  @spec quiet_leads(binary(), DateTime.t(), [binary()] | nil) :: [Lead.t()]
  def quiet_leads(organisation_id, %DateTime{} = cutoff, team_ids \\ nil) do
    from(l in Lead,
      join: j in assoc(l, :job),
      as: :job,
      where:
        l.organisation_id == ^organisation_id and is_nil(l.archived_at) and not l.is_pinned and
          l.last_activity_at <= ^cutoff,
      order_by: [asc: l.last_activity_at, asc: l.id]
    )
    |> teams(team_ids)
    |> Leads.load_all()
  end

  @doc "Archived, unpinned leads archived at `cutoff` or before. `team_ids` narrows."
  @spec archived_leads(binary(), DateTime.t(), [binary()] | nil) :: [Lead.t()]
  def archived_leads(organisation_id, %DateTime{} = cutoff, team_ids \\ nil) do
    from(l in Lead,
      join: j in assoc(l, :job),
      as: :job,
      where:
        l.organisation_id == ^organisation_id and not is_nil(l.archived_at) and
          not l.is_pinned and l.archived_at <= ^cutoff,
      order_by: [asc: l.archived_at, asc: l.id]
    )
    |> teams(team_ids)
    |> Leads.load_all()
  end

  @doc "The newest `archive_warned` of each lead: `%{lead_id => occurred_at}`."
  @spec warned_at([binary()]) :: %{binary() => DateTime.t()}
  def warned_at([]), do: %{}

  def warned_at(lead_ids) do
    from(e in Event,
      where: e.lead_id in ^lead_ids and e.kind == :archive_warned,
      group_by: e.lead_id,
      select: {e.lead_id, max(e.occurred_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Every ledger row of a lead, oldest first (what a fingerprint reads)."
  @spec all_events(binary()) :: [Event.t()]
  def all_events(lead_id) do
    Repo.all(
      from(e in Event,
        where: e.lead_id == ^lead_id,
        order_by: [asc: e.occurred_at, asc: e.recorded_at, asc: e.id]
      )
    )
  end

  @doc "Deletes a lead; its events, notes, labels, share links and notifications cascade, its tasks are unlinked."
  @spec delete_lead(Lead.t()) :: {:ok, Lead.t()} | {:error, Ecto.Changeset.t()}
  def delete_lead(%Lead{} = lead), do: Repo.delete(lead)

  # ── Jobs ────────────────────────────────────────────────────────────────────

  @doc """
  Live jobs with no unarchived lead, quiet since `cutoff` or longer (their
  `last_activity_at`, else when first seen). `team_ids` narrows.
  """
  @spec quiet_jobs(binary(), DateTime.t(), [binary()] | nil) :: [Job.t()]
  def quiet_jobs(organisation_id, %DateTime{} = cutoff, team_ids \\ nil) do
    live = from(l in Lead, where: is_nil(l.archived_at), select: l.job_id)

    from(j in Job,
      as: :job,
      where:
        j.organisation_id == ^organisation_id and is_nil(j.archived_at) and
          coalesce(j.last_activity_at, j.first_seen_at) <= ^cutoff and
          j.id not in subquery(live),
      order_by: [asc: j.last_activity_at, asc: j.id],
      preload: [:company, :team]
    )
    |> teams(team_ids)
    |> Repo.all()
  end

  @doc "Archived jobs archived at `cutoff` or before, with no lead left. `team_ids` narrows."
  @spec bare_archived_jobs(binary(), DateTime.t(), [binary()] | nil) :: [Job.t()]
  def bare_archived_jobs(organisation_id, %DateTime{} = cutoff, team_ids \\ nil) do
    any = from(l in Lead, select: l.job_id)

    from(j in Job,
      as: :job,
      where:
        j.organisation_id == ^organisation_id and not is_nil(j.archived_at) and
          j.archived_at <= ^cutoff and j.id not in subquery(any),
      order_by: [asc: j.archived_at, asc: j.id],
      preload: [:company, :team]
    )
    |> teams(team_ids)
    |> Repo.all()
  end

  @doc "How many leads a job has: `{unarchived, all}`."
  @spec lead_counts(binary()) :: {non_neg_integer(), non_neg_integer()}
  def lead_counts(job_id) do
    from(l in Lead,
      where: l.job_id == ^job_id,
      select: {count(fragment("CASE WHEN ? IS NULL THEN 1 END", l.archived_at)), count()}
    )
    |> Repo.one()
  end

  defp teams(query, nil), do: query
  defp teams(query, team_ids), do: where(query, [job: j], j.team_id in ^team_ids)

  # ── Tombstones ──────────────────────────────────────────────────────────────

  @spec add_fingerprint(map()) :: {:ok, Fingerprint.t()} | {:error, Ecto.Changeset.t()}
  def add_fingerprint(attrs), do: %Fingerprint{} |> Fingerprint.changeset(attrs) |> Repo.insert()

  @doc "The tombstones on a posting's keys, oldest first, with their profiles."
  @spec fingerprints_on(binary(), [String.t()]) :: [Fingerprint.t()]
  def fingerprints_on(_organisation_id, []), do: []

  def fingerprints_on(organisation_id, keys) do
    from(f in Fingerprint,
      where: f.organisation_id == ^organisation_id and f.canonical_key in ^keys,
      order_by: [asc: f.purged_at, asc: f.id],
      preload: [:profile]
    )
    |> Repo.all()
  end
end
