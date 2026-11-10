defmodule Data.Customers.Profile do
  @moduledoc """
  One way of marketing a customer (JH-01 §4.3; PLAN §4). Two changesets
  because two rights (QP1-7): `pitch_changeset/2` for title, headline and
  summary — a lead's or the customer's — and `facts_changeset/2` for the
  rest, which a member may edit too. `Core.Access` decides which applies;
  this module only knows which field is which.

  The default CV is the link row `profile_default_documents`, read through
  `default_document_id/1`.
  """

  use Data.Schema

  alias Data.Customers.{Customer, Document, ProfileChannel, ProfileDefaultDocument}
  alias Data.Customers.{ProfileMember, ProfileSkill}
  alias Data.Vocabulary

  @seniorities Vocabulary.seniorities() |> Enum.map(&String.to_atom/1)
  @periods Vocabulary.comp_periods() |> Enum.map(&String.to_atom/1)
  @pipelines Vocabulary.pipeline_keys() |> Enum.map(&String.to_atom/1)
  @statuses Vocabulary.profile_statuses() |> Enum.map(&String.to_atom/1)

  @pitch_fields ~w(title headline summary_md)a
  @facts_fields ~w(seniority years_experience engagement_types workplace_types
                   min_comp_minor min_comp_currency min_comp_period work_timezones
                   work_countries visa_note notice_days available_from_on daily_target
                   default_pipeline_key status)a

  @type t :: %__MODULE__{}

  schema "profiles" do
    field(:title, :string)
    field(:headline, :string)
    field(:summary_md, :string)
    field(:seniority, Ecto.Enum, values: @seniorities)
    field(:years_experience, :integer)
    field(:engagement_types, {:array, :string}, default: [])
    field(:workplace_types, {:array, :string}, default: [])
    field(:min_comp_minor, :integer)
    field(:min_comp_currency, :string)
    field(:min_comp_period, Ecto.Enum, values: @periods)
    field(:work_timezones, {:array, :string}, default: [])
    field(:work_countries, {:array, :string}, default: [])
    field(:visa_note, :string)
    field(:notice_days, :integer)
    field(:available_from_on, :date)
    field(:daily_target, :integer, default: 35)
    field(:default_pipeline_key, Ecto.Enum, values: @pipelines, default: :employment)
    field(:status, Ecto.Enum, values: @statuses, default: :active)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:customer, Customer)
    has_many(:profile_members, ProfileMember)
    has_many(:profile_skills, ProfileSkill)
    has_many(:profile_channels, ProfileChannel)
    has_many(:documents, Document)
    has_one(:default_document_link, ProfileDefaultDocument)

    timestamps()
  end

  @doc "Title, headline, summary: how the customer is presented."
  def pitch_fields, do: @pitch_fields

  @doc "Skills' companions: targets, availability, the money floor, and the rest."
  def facts_fields, do: @facts_fields

  @doc "The default document's id, or `nil` (also when the link is not loaded)."
  @spec default_document_id(t()) :: binary() | nil
  def default_document_id(%__MODULE__{default_document_link: %ProfileDefaultDocument{} = link}),
    do: link.document_id

  def default_document_id(%__MODULE__{}), do: nil

  @doc "A new profile: the pitch and the facts together, under the customer."
  def create_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:customer_id | @pitch_fields ++ @facts_fields])
    |> validate_required([:customer_id])
    |> validate_pitch()
    |> validate_facts()
    |> foreign_key_constraint(:customer_id)
  end

  def pitch_changeset(profile, attrs),
    do: profile |> cast(attrs, @pitch_fields) |> validate_pitch()

  def facts_changeset(profile, attrs),
    do: profile |> cast(attrs, @facts_fields) |> validate_facts()

  defp validate_pitch(changeset) do
    changeset
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 120)
    |> validate_length(:headline, max: 220)
    |> validate_length(:summary_md, max: 20_000)
    |> check_constraint(:title, name: :title_present)
    |> unique_constraint([:customer_id, :title],
      name: :profiles_live_title_index,
      error_key: :title,
      message: "is already one of this customer's profiles"
    )
  end

  defp validate_facts(changeset) do
    changeset
    |> validate_number(:years_experience, greater_than_or_equal_to: 0, less_than: 80)
    |> validate_number(:notice_days, greater_than_or_equal_to: 0, less_than: 1000)
    |> validate_number(:daily_target, greater_than_or_equal_to: 0, less_than: 1000)
    |> validate_number(:min_comp_minor, greater_than_or_equal_to: 0)
    |> validate_subset(:engagement_types, Vocabulary.engagement_types())
    |> validate_subset(:workplace_types, Vocabulary.workplace_types())
    |> validate_format(:min_comp_currency, ~r/^[A-Z]{3}$/, message: "is not an ISO currency code")
    |> validate_length(:visa_note, max: 500)
    |> validate_money_floor()
    |> check_constraint(:seniority, name: :seniority_known)
    |> check_constraint(:engagement_types, name: :engagement_types_known)
    |> check_constraint(:workplace_types, name: :workplace_types_known)
    |> check_constraint(:min_comp_period, name: :min_comp_period_known)
    |> check_constraint(:min_comp_minor, name: :min_comp_whole)
    |> check_constraint(:default_pipeline_key, name: :default_pipeline_key_known)
    |> check_constraint(:status, name: :status_known)
  end

  # Minor units, a currency and a period together, or none of them: a floor
  # without its currency is a number that means nothing.
  defp validate_money_floor(changeset) do
    parts = [:min_comp_minor, :min_comp_currency, :min_comp_period]
    set = Enum.reject(parts, &is_nil(get_field(changeset, &1)))

    if set == [] or length(set) == 3,
      do: changeset,
      else:
        Enum.reduce(parts -- set, changeset, fn field, acc ->
          add_error(acc, field, "is needed with the rest of the money floor")
        end)
  end
end
