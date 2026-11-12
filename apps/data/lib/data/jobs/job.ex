defmodule Data.Jobs.Job do
  @moduledoc """
  A job in one team's pool (AQ-03 §5.1, AQ-03B §4). Its identity — the
  team, `source`, `canonical_key`, `source_job_id`, `source_url` — is set at
  creation (the key from `Utils.JobKey`) and never changes; `changeset/2` is everything else a person sets (`POST` and
  `PATCH /jobs`), `close_changeset/2` and `archive_changeset/3` are the
  verbs', `fill_changeset/2` a merge's. Who may do which is `Core.Access`'s;
  the CHECKs in the migration hold the shape.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Companies.Company
  alias Data.Jobs.{Dismissal, JobSkill, Snapshot}
  alias Data.Organisations.Organisation
  alias Data.Teams.Team
  alias Data.Vocabulary

  @sources Vocabulary.job_sources() |> Enum.map(&String.to_atom/1)
  @origins Vocabulary.job_origins() |> Enum.map(&String.to_atom/1)
  @seniorities Vocabulary.seniorities() |> Enum.map(&String.to_atom/1)
  @workplaces Vocabulary.workplace_types() |> Enum.map(&String.to_atom/1)
  @remote_scopes Vocabulary.remote_scopes() |> Enum.map(&String.to_atom/1)
  @visas Vocabulary.visa_policies() |> Enum.map(&String.to_atom/1)
  @engagements Vocabulary.engagement_types() |> Enum.map(&String.to_atom/1)
  @durations Vocabulary.durations() |> Enum.map(&String.to_atom/1)
  @periods Vocabulary.comp_periods() |> Enum.map(&String.to_atom/1)
  @comp_sources Vocabulary.comp_sources() |> Enum.map(&String.to_atom/1)
  @equity_kinds Vocabulary.equity_kinds() |> Enum.map(&String.to_atom/1)
  @apply_methods Vocabulary.apply_methods() |> Enum.map(&String.to_atom/1)
  @statuses Vocabulary.job_statuses() |> Enum.map(&String.to_atom/1)
  @close_reasons Vocabulary.job_close_reasons() |> Enum.map(&String.to_atom/1)

  @identity ~w(organisation_id team_id source source_url canonical_key source_job_id origin first_seen_at
               last_seen_at created_by_user_id)a

  # Everything a person sets: the link, the key, the status and the
  # lifecycle columns are the verbs'; `description_html` is a capture's (P5).
  @editable ~w(is_reposted company_id poster_name title description_md seniority category openings
               workplace remote_scope allowed_countries allowed_regions required_timezones
               min_overlap_hours overlap_from_time overlap_to_time onsite_locations
               is_relocation_offered visa visa_text engagement duration hours_min hours_max start_on
               is_immediate_start comp_min_minor comp_max_minor comp_currency comp_period
               comp_source comp_text is_comp_undisclosed equity_min_bp equity_max_bp equity_kind
               apply_method apply_url posted_on valid_through_on)a

  @type t :: %__MODULE__{}

  schema "jobs" do
    field(:source, Ecto.Enum, values: @sources)
    field(:source_url, :string)
    field(:canonical_key, :string)
    field(:source_job_id, :string)
    field(:origin, Ecto.Enum, values: @origins, default: :manual)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:is_reposted, :boolean, default: false)

    field(:poster_name, :string)
    field(:title, :string)
    field(:description_md, :string)
    field(:description_html, :string)
    field(:seniority, Ecto.Enum, values: @seniorities)
    field(:category, :string)
    field(:openings, :integer)

    field(:workplace, Ecto.Enum, values: @workplaces)
    field(:remote_scope, Ecto.Enum, values: @remote_scopes)
    field(:allowed_countries, {:array, :string}, default: [])
    field(:allowed_regions, {:array, :string}, default: [])
    field(:required_timezones, {:array, :string}, default: [])
    field(:min_overlap_hours, :integer)
    field(:overlap_from_time, :time)
    field(:overlap_to_time, :time)
    field(:onsite_locations, {:array, :string}, default: [])
    field(:is_relocation_offered, :boolean)
    field(:visa, Ecto.Enum, values: @visas)
    field(:visa_text, :string)

    field(:engagement, Ecto.Enum, values: @engagements)
    field(:duration, Ecto.Enum, values: @durations)
    field(:hours_min, :integer)
    field(:hours_max, :integer)
    field(:start_on, :date)
    field(:is_immediate_start, :boolean, default: false)

    field(:comp_min_minor, :integer)
    field(:comp_max_minor, :integer)
    field(:comp_currency, :string)
    field(:comp_period, Ecto.Enum, values: @periods)
    field(:comp_source, Ecto.Enum, values: @comp_sources)
    field(:comp_text, :string)
    field(:is_comp_undisclosed, :boolean, default: false)
    field(:equity_min_bp, :integer)
    field(:equity_max_bp, :integer)
    field(:equity_kind, Ecto.Enum, values: @equity_kinds)

    field(:apply_method, Ecto.Enum, values: @apply_methods)
    field(:apply_url, :string)

    field(:posted_on, :date)
    field(:valid_through_on, :date)
    field(:status, Ecto.Enum, values: @statuses, default: :open)
    field(:closed_at, :utc_datetime_usec)
    field(:close_reason, Ecto.Enum, values: @close_reasons)
    field(:last_activity_at, :utc_datetime_usec)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:created_by_user, User)
    belongs_to(:company, Company)
    belongs_to(:closed_by_user, User)
    belongs_to(:archived_by_user, User)

    has_many(:job_skills, JobSkill)
    has_many(:snapshots, Snapshot, preload_order: [desc: :captured_at])
    has_many(:dismissals, Dismissal)

    timestamps()
  end

  @doc "What `POST` and `PATCH /jobs` may set."
  def editable_fields, do: @editable

  @doc """
  A new job: its identity (from the link) and what the person set; a
  capture's `description_html` too (AQ-05 §10.1: the server sanitised it).
  """
  def create_changeset(job, attrs) do
    job
    |> cast(attrs, @identity ++ [:last_activity_at, :description_html])
    |> validate_required([:organisation_id, :team_id, :source, :source_url, :canonical_key])
    |> validate_required([:origin, :first_seen_at, :last_seen_at])
    |> unique_constraint([:team_id, :canonical_key],
      error_key: :url,
      message: "is already in the pool"
    )
    |> changeset(attrs)
  end

  @doc "What a person sets, at creation and on `PATCH`."
  def changeset(job, attrs) do
    job
    |> cast(attrs, @editable ++ [:last_activity_at])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> update_change(:comp_currency, &(&1 && String.upcase(String.trim(&1))))
    |> update_change(:allowed_countries, &upcase_all/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 300)
    |> validate_length(:poster_name, max: 200)
    |> validate_length(:category, max: 120)
    |> validate_length(:description_md, max: 100_000)
    |> validate_number(:openings, greater_than_or_equal_to: 1, less_than: 10_000)
    |> validate_number(:min_overlap_hours, greater_than_or_equal_to: 0, less_than_or_equal_to: 24)
    |> validate_number(:hours_min, greater_than_or_equal_to: 0, less_than: 200)
    |> validate_number(:hours_max, greater_than_or_equal_to: 0, less_than: 200)
    |> validate_number(:comp_min_minor, greater_than_or_equal_to: 0)
    |> validate_number(:comp_max_minor, greater_than_or_equal_to: 0)
    |> validate_number(:equity_min_bp, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:equity_max_bp, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_format(:comp_currency, ~r/^[A-Z]{3}$/, message: "is not an ISO currency code")
    |> validate_subset(:allowed_regions, Vocabulary.regions())
    |> validate_change(:allowed_countries, &countries/2)
    |> validate_change(:required_timezones, &zones/2)
    |> validate_change(:apply_url, &link/2)
    |> ordered(:comp_min_minor, :comp_max_minor)
    |> ordered(:equity_min_bp, :equity_max_bp)
    |> ordered(:hours_min, :hours_max)
    |> money_whole()
    |> rules()
  end

  @doc "Close (`status: closed` with `closed_at`, the reason and who) or reopen."
  def close_changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :closed_at, :close_reason, :closed_by_user_id, :last_activity_at])
    |> validate_required([:status])
    |> rules()
  end

  @doc "Archive (`at`) or unarchive (`nil`)."
  def archive_changeset(job, at, user_id),
    do: change(job, archived_at: at, archived_by_user_id: at && user_id)

  @doc """
  A fill of the job's blanks, nothing else: a merge's from the merged job,
  or a capture's from the page (AQ-05 §10.2, which may fill
  `description_html` too).
  """
  def fill_changeset(job, attrs),
    do: job |> cast(attrs, [:description_html | @editable]) |> rules()

  defp upcase_all(nil), do: nil
  defp upcase_all(codes), do: Enum.map(codes, &(&1 |> String.trim() |> String.upcase()))

  defp countries(field, codes) do
    if Enum.all?(codes, &(&1 =~ ~r/^[A-Z]{2}$/)),
      do: [],
      else: [{field, "has a code that is not an ISO country code"}]
  end

  defp zones(field, zones) do
    if Enum.all?(zones, &match?({:ok, _now}, DateTime.now(&1))),
      do: [],
      else: [{field, "has a zone that is not a known IANA timezone"}]
  end

  defp link(field, url),
    do: if(Utils.SafeUrl.safe?(url), do: [], else: [{field, "is not a web link"}])

  defp ordered(changeset, low, high) do
    case {get_field(changeset, low), get_field(changeset, high)} do
      {a, b} when is_integer(a) and is_integer(b) and a > b ->
        add_error(changeset, low, "is more than #{high}")

      _ordered ->
        changeset
    end
  end

  # An amount needs its currency and its period (CONVENTIONS §3).
  defp money_whole(changeset) do
    amount? = get_field(changeset, :comp_min_minor) || get_field(changeset, :comp_max_minor)

    Enum.reduce([:comp_currency, :comp_period], changeset, fn field, acc ->
      if amount? && is_nil(get_field(acc, field)),
        do: add_error(acc, field, "is needed with an amount"),
        else: acc
    end)
  end

  defp rules(changeset) do
    changeset
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
    |> check_constraint(:source, name: :source_known)
    |> check_constraint(:origin, name: :origin_known)
    |> check_constraint(:seniority, name: :seniority_known)
    |> check_constraint(:workplace, name: :workplace_known)
    |> check_constraint(:remote_scope, name: :remote_scope_known)
    |> check_constraint(:visa, name: :visa_known)
    |> check_constraint(:engagement, name: :engagement_known)
    |> check_constraint(:duration, name: :duration_known)
    |> check_constraint(:comp_period, name: :comp_period_known)
    |> check_constraint(:comp_source, name: :comp_source_known)
    |> check_constraint(:equity_kind, name: :equity_kind_known)
    |> check_constraint(:apply_method, name: :apply_method_known)
    |> check_constraint(:status, name: :status_known)
    |> check_constraint(:close_reason, name: :close_reason_known)
    |> check_constraint(:comp_min_minor,
      name: :comp_range,
      message: "is more than comp_max_minor"
    )
    |> check_constraint(:comp_min_minor, name: :comp_not_negative)
    |> check_constraint(:comp_currency, name: :comp_whole, message: "is needed with an amount")
    |> check_constraint(:comp_currency, name: :comp_currency_iso)
    |> check_constraint(:equity_min_bp, name: :equity_range)
    |> check_constraint(:hours_min, name: :hours_range)
    |> check_constraint(:openings, name: :openings_positive)
    |> check_constraint(:min_overlap_hours, name: :min_overlap_hours_range)
    |> check_constraint(:allowed_countries, name: :allowed_countries_iso)
    |> check_constraint(:allowed_regions, name: :allowed_regions_known)
    |> check_constraint(:closed_at, name: :closed_matches_status)
    |> check_constraint(:close_reason, name: :close_reason_only_closed)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:organisation_id)
    |> foreign_key_constraint(:team_id)
  end
end
