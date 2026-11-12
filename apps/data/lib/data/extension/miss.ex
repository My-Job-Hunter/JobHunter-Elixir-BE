defmodule Data.Extension.Miss do
  @moduledoc """
  How often a selector missed on one day (AQ-05 §5.2, QP5-22): per
  organisation, site, selector, config version and extension version, in
  the organisation's zone. A report adds to `count`. No address and no page
  text.
  """

  use Data.Schema

  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @sites Vocabulary.ext_sites() |> Enum.map(&String.to_atom/1)
  @page_kinds Vocabulary.ext_page_kinds() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "extension_misses" do
    field(:site, Ecto.Enum, values: @sites)
    field(:page_kind, Ecto.Enum, values: @page_kinds)
    field(:selector_key, :string)
    field(:config_version, :integer)
    field(:extension_version, :string)
    field(:seen_on, :date)
    field(:count, :integer)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
  end

  @fields ~w(organisation_id site page_kind selector_key config_version extension_version seen_on
             count first_seen_at last_seen_at)a

  def changeset(miss, attrs) do
    miss
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_format(:selector_key, ~r/^[a-z][a-z0-9_.]{0,59}$/)
    |> validate_length(:extension_version, min: 1, max: 20)
    |> validate_number(:count, greater_than_or_equal_to: 1)
    |> validate_number(:config_version, greater_than_or_equal_to: 0)
    |> check_constraint(:site, name: :site_known)
    |> check_constraint(:page_kind, name: :page_kind_known)
    |> check_constraint(:count, name: :count_positive)
    |> check_constraint(:selector_key, name: :selector_key_shape)
    |> foreign_key_constraint(:organisation_id)
  end
end
