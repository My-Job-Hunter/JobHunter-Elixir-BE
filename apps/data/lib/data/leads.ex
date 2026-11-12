defmodule Data.Leads do
  @moduledoc """
  Leads and their ledger (AQ-04A §5.2). Storage only: who sees and moves a
  lead is `Core.Access.Leads`'s, the verbs `Core.Leads.Act`'s, the guard
  `Core.Leads.Guard`'s.

  Every lead read here comes with what a card shows: its job (with company
  and team), its profile (with its customer and `team_ids`), its owner, its
  stage and its pipeline version with the version's stages. `sheet/1` adds
  the sheet's people and the CV.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Jobs.{Job, Merge}
  alias Data.Leads.{Event, Lead}
  alias Data.Repo

  @person [person: :photo]
  @base [
    :stage,
    job: [:company, :team],
    profile: [customer: [:customer_teams]],
    owner_user: @person,
    pipeline_version: :stages
  ]
  @sheet [applied_by_user: @person, created_by_user: @person, document: []]

  @doc "What every lead read carries."
  def base_preload, do: @base

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "A lead of the organisation; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Lead.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Lead |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()
      :error -> nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The lead again, with everything fresh."
  @spec reload(Lead.t()) :: Lead.t()
  def reload(%Lead{} = lead), do: Lead |> Repo.get!(lead.id) |> load()

  @doc "The lead with its sheet's people and its CV."
  @spec sheet(Lead.t()) :: Lead.t()
  def sheet(%Lead{} = lead), do: Repo.preload(lead, @sheet)

  @doc """
  A team's leads for its board (§8.1): `filters` holds `archived` (only the
  archived when true, else only the live), `visible_to` (`:all`, or a user
  id whose own leads alone show: owner or applier), `customer_id`,
  `profile_id`, `owner_user_id`, `sources`, `engagements`, `workplaces`
  (atoms), `stage_key`, `pipeline_key`, `q` (normalised text: title or
  company), `quiet_before` (last activity before this instant) and — the
  Tracker's and P4b's board — `states`, `outcomes` (atoms) and `label_ids`
  (wearing any of them).
  """
  @spec for_team(binary(), map()) :: [Lead.t()]
  def for_team(team_id, filters) do
    from(l in Lead,
      as: :lead,
      join: j in assoc(l, :job),
      as: :job,
      where: j.team_id == ^team_id
    )
    |> archived(Map.get(filters, :archived, false))
    |> visible_to(Map.get(filters, :visible_to, :all))
    |> equal(:profile_id, filters[:profile_id])
    |> equal(:owner_user_id, filters[:owner_user_id])
    |> customer(filters[:customer_id])
    |> job_any(:source, filters[:sources])
    |> job_any(:engagement, filters[:engagements])
    |> job_any(:workplace, filters[:workplaces])
    |> stage_key(filters[:stage_key])
    |> pipeline_key(filters[:pipeline_key])
    |> search(filters[:q])
    |> quiet(filters[:quiet_before])
    |> any_of(:state, filters[:states])
    |> any_of(:outcome, filters[:outcomes])
    |> labelled(filters[:label_ids])
    |> order_by([l], desc: l.last_activity_at, desc: l.id)
    |> load_all()
  end

  @doc "Runs a lead query with what every lead read carries."
  @spec load_all(Ecto.Queryable.t()) :: [Lead.t()]
  def load_all(query), do: query |> preload(^@base) |> Repo.all() |> Enum.map(&fill/1)

  defp any_of(query, _field, nil), do: query
  defp any_of(query, _field, []), do: query
  defp any_of(query, field, values), do: where(query, [l], field(l, ^field) in ^values)

  defp labelled(query, nil), do: query
  defp labelled(query, []), do: query

  defp labelled(query, label_ids) do
    worn = from(ll in Data.Labels.LeadLabel, where: ll.label_id in ^label_ids, select: ll.lead_id)
    where(query, [l], l.id in subquery(worn))
  end

  defp archived(query, true), do: where(query, [l], not is_nil(l.archived_at))
  defp archived(query, _live), do: where(query, [l], is_nil(l.archived_at))

  defp visible_to(query, :all), do: query

  defp visible_to(query, me) when is_binary(me),
    do: where(query, [l], l.owner_user_id == ^me or l.applied_by_user_id == ^me)

  defp equal(query, _field, nil), do: query
  defp equal(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  defp customer(query, nil), do: query

  defp customer(query, customer_id) do
    query
    |> join(:inner, [l], p in assoc(l, :profile), as: :profile)
    |> where([profile: p], p.customer_id == ^customer_id)
  end

  defp job_any(query, _field, nil), do: query
  defp job_any(query, _field, []), do: query
  defp job_any(query, field, values), do: where(query, [job: j], field(j, ^field) in ^values)

  defp stage_key(query, nil), do: query

  defp stage_key(query, key) do
    query
    |> join(:inner, [l], s in assoc(l, :stage), as: :stage)
    |> where([stage: s], s.key == ^key)
  end

  defp pipeline_key(query, nil), do: query

  defp pipeline_key(query, key) do
    query
    |> join(:inner, [l], v in assoc(l, :pipeline_version), as: :version)
    |> where([version: v], v.pipeline_key == ^key)
  end

  defp search(query, nil), do: query

  defp search(query, qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"

    query
    |> join(:left, [job: j], c in assoc(j, :company), as: :company)
    |> where(
      [job: j, company: c],
      fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or like(c.name_normalized, ^like)
    )
  end

  defp quiet(query, nil), do: query
  defp quiet(query, %DateTime{} = before), do: where(query, [l], l.last_activity_at < ^before)

  @doc "The leads on these jobs, every one (the guard and the job's panel narrow them)."
  @spec for_jobs([binary()]) :: [Lead.t()]
  def for_jobs([]), do: []

  def for_jobs(job_ids) do
    from(l in Lead,
      where: l.job_id in ^job_ids,
      order_by: [desc: l.last_activity_at, desc: l.id],
      preload: ^(@base ++ @sheet)
    )
    |> Repo.all()
    |> Enum.map(&fill/1)
  end

  @doc """
  Every lead of the organisation on a posting (§6): whose job's canonical
  key is one of `keys`, or whose job had one of them merged in
  (`job_merges`), in any team — with what the guard names.
  """
  @spec on_posting(binary(), [String.t()]) :: [Lead.t()]
  def on_posting(_organisation_id, []), do: []

  def on_posting(organisation_id, keys) do
    merged = from(m in Merge, where: m.from_canonical_key in ^keys, select: m.into_job_id)

    from(l in Lead,
      join: j in assoc(l, :job),
      where:
        l.organisation_id == ^organisation_id and
          (j.canonical_key in ^keys or j.id in subquery(merged)),
      order_by: [asc: l.inserted_at],
      preload: ^(@base ++ @sheet)
    )
    |> Repo.all()
    |> Enum.map(&fill/1)
  end

  @doc """
  The keys of a posting (§6): `key`, and every key merged into a job that
  holds `key` now, in any team of the organisation.
  """
  @spec posting_keys(binary(), String.t()) :: [String.t()]
  def posting_keys(organisation_id, key) do
    merged =
      from(m in Merge,
        join: j in Job,
        on: j.id == m.into_job_id,
        where: j.organisation_id == ^organisation_id and j.canonical_key == ^key,
        select: m.from_canonical_key
      )
      |> Repo.all()

    Enum.uniq([key | merged])
  end

  @doc """
  The posting keys where a profile has a lead past To do, in any team: its
  jobs' canonical keys and every key merged into them. What `GET
  /jobs?not_applied_with=` leaves out (AQ-04A §8.1).
  """
  @spec applied_keys(binary(), binary()) :: [String.t()]
  def applied_keys(organisation_id, profile_id) do
    jobs =
      from(l in Lead,
        join: j in assoc(l, :job),
        where:
          l.organisation_id == ^organisation_id and l.profile_id == ^profile_id and
            l.state != :todo,
        select: {j.id, j.canonical_key}
      )
      |> Repo.all()

    merged =
      from(m in Merge,
        where: m.into_job_id in ^Enum.map(jobs, &elem(&1, 0)),
        select: m.from_canonical_key
      )
      |> Repo.all()

    Enum.uniq(Enum.map(jobs, &elem(&1, 1)) ++ merged)
  end

  @doc "A customer's leads, from every team: their profiles', with what a card shows."
  @spec for_customer(binary(), keyword()) :: [Lead.t()]
  def for_customer(customer_id, opts \\ []) do
    query =
      from(l in Lead,
        join: p in assoc(l, :profile),
        where: p.customer_id == ^customer_id,
        order_by: [desc: l.last_activity_at, desc: l.id],
        preload: ^(@base ++ @sheet)
      )

    query =
      if Keyword.get(opts, :archived, false),
        do: query,
        else: where(query, [l], is_nil(l.archived_at))

    query |> Repo.all() |> Enum.map(&fill/1)
  end

  @doc "The ids of the profiles with a lead on both jobs: what refuses a merge (QP4a-17)."
  @spec profiles_on_both(binary(), binary()) :: [binary()]
  def profiles_on_both(job_a, job_b) do
    from(a in Lead,
      join: b in Lead,
      on: b.profile_id == a.profile_id,
      where: a.job_id == ^job_a and b.job_id == ^job_b,
      select: a.profile_id
    )
    |> Repo.all()
  end

  @doc "Every lead of a job, re-pointed to another (a merge). Answers how many."
  @spec move_to_job(binary(), binary()) :: non_neg_integer()
  def move_to_job(from_job_id, to_job_id) do
    {count, _rows} =
      from(l in Lead, where: l.job_id == ^from_job_id)
      |> Repo.update_all(set: [job_id: to_job_id])

    count
  end

  @doc "The newest `limit` events of a lead (all of them when `limit` is nil), with their actors."
  @spec events(binary(), pos_integer() | nil) :: [Event.t()]
  def events(lead_id, limit \\ nil) do
    query =
      from(e in Event,
        where: e.lead_id == ^lead_id,
        order_by: [desc: e.occurred_at, desc: e.recorded_at, desc: e.id],
        preload: [:lead_note, actor_user: ^@person]
      )

    query = if limit, do: limit(query, ^limit), else: query
    Repo.all(query)
  end

  @doc """
  A page of a lead's ledger, newest first (AQ-04B §8.1 History): `kinds`
  narrows (nil or `[]`: every kind), `before` is the event to start after
  (its `{occurred_at, recorded_at, id}`), `visibility` narrows to one
  (`:customer` for the portal). Reads `limit + 1` so the caller knows if
  there is more.
  """
  @spec history(binary(), keyword()) :: [Event.t()]
  def history(lead_id, opts) do
    from(e in Event,
      where: e.lead_id == ^lead_id,
      order_by: [desc: e.occurred_at, desc: e.recorded_at, desc: e.id],
      limit: ^(Keyword.fetch!(opts, :limit) + 1),
      preload: [:lead_note, actor_user: ^@person]
    )
    |> kinds(opts[:kinds])
    |> visibility(opts[:visibility])
    |> before(opts[:before])
    |> Repo.all()
  end

  defp kinds(query, nil), do: query
  defp kinds(query, []), do: query
  defp kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  defp visibility(query, nil), do: query
  defp visibility(query, v), do: where(query, [e], e.visibility == ^v)

  defp before(query, nil), do: query

  defp before(query, %Event{occurred_at: at, recorded_at: rec, id: id}) do
    where(
      query,
      [e],
      e.occurred_at < ^at or (e.occurred_at == ^at and e.recorded_at < ^rec) or
        (e.occurred_at == ^at and e.recorded_at == ^rec and e.id < ^id)
    )
  end

  @doc "One event of a lead; `nil` for a malformed id or another lead's."
  @spec event(binary(), term()) :: Event.t() | nil
  def event(lead_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Event, id: uuid, lead_id: lead_id)
      :error -> nil
    end
  end

  def event(_lead_id, _id), do: nil

  @doc """
  The event of the organisation a queued write made (`request_id`, AQ-05
  §10.4), or `nil`: what a retry of a write that landed is answered from.
  """
  @spec event_by_request(binary(), term()) :: Event.t() | nil
  def event_by_request(organisation_id, request_id) when is_binary(request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, uuid} -> Repo.get_by(Event, request_id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  def event_by_request(_organisation_id, _request_id), do: nil

  @signal_kinds [:applied, :follow_up_logged, :follow_up_due, :archive_warned, :message_in]

  @doc """
  What *Next*, follow-ups and the quiet clock read of each lead's ledger:
  its `applied`, `follow_up_logged`, `follow_up_due`, `archive_warned`
  and (AQ-06) `message_in` rows (`kind`, `occurred_at`), `%{lead_id => [row]}`.
  """
  @spec signal_events([binary()]) :: %{binary() => [map()]}
  def signal_events([]), do: %{}

  def signal_events(lead_ids) do
    from(e in Event,
      where: e.lead_id in ^lead_ids and e.kind in ^@signal_kinds,
      select: %{lead_id: e.lead_id, kind: e.kind, occurred_at: e.occurred_at}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.lead_id)
  end

  @doc "Every lead of the organisation still in progress (the follow-up scan's candidates)."
  @spec in_progress_for_system(binary()) :: [Lead.t()]
  def in_progress_for_system(organisation_id) do
    from(l in Lead,
      where:
        l.organisation_id == ^organisation_id and l.state == :in_progress and
          is_nil(l.archived_at)
    )
    |> load_all()
  end

  defp load(nil), do: nil
  defp load(lead), do: lead |> Repo.preload(@base, force: true) |> fill()

  @doc "The profile's customer with its `team_ids`, as `Core.Access` reads it (a lead read elsewhere)."
  @spec fill(Lead.t() | nil) :: Lead.t() | nil
  def fill(%Lead{profile: %{customer: %{} = customer} = profile} = lead),
    do: %{lead | profile: %{profile | customer: Customers.fill(customer)}}

  def fill(lead), do: lead

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Lead.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, lead} <- %Lead{} |> Lead.changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(lead)}
  end

  @spec update(Lead.t(), map()) :: {:ok, Lead.t()} | {:error, Ecto.Changeset.t()}
  def update(%Lead{} = lead, attrs) do
    with {:ok, updated} <- lead |> Lead.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "Touches `last_activity_at`."
  @spec touch(Lead.t(), DateTime.t()) :: :ok
  def touch(%Lead{} = lead, %DateTime{} = at) do
    {1, _rows} =
      Repo.update_all(from(l in Lead, where: l.id == ^lead.id), set: [last_activity_at: at])

    :ok
  end

  @doc "A ledger row: append-only."
  @spec add_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def add_event(attrs), do: %Event{} |> Event.changeset(attrs) |> Repo.insert()

  @doc """
  A transaction-scoped advisory lock on (organisation, canonical key,
  profile): two teams saving the same profile on the same posting at once
  are kept apart (§6).
  """
  @spec lock(binary(), String.t(), binary()) :: :ok
  def lock(organisation_id, key, profile_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "lead:#{organisation_id}:#{key}:#{profile_id}"
    ])

    :ok
  end
end
