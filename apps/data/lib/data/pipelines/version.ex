defmodule Data.Pipelines.Version do
  @moduledoc """
  One version of one of the organisation's two pipelines (AQ-04A §5.1): the
  newest number is the live one. Append-only, so only `inserted_at`.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation
  alias Data.Pipelines.Stage

  @keys Data.Vocabulary.pipeline_keys() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "pipeline_versions" do
    field(:pipeline_key, Ecto.Enum, values: @keys)
    field(:number, :integer)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:organisation, Organisation)
    belongs_to(:created_by_user, User)
    has_many(:stages, Stage, foreign_key: :pipeline_version_id, preload_order: [asc: :position])
  end

  @doc "The keys, as atoms."
  def keys, do: @keys

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:organisation_id, :pipeline_key, :number, :created_by_user_id, :inserted_at])
    |> validate_required([:organisation_id, :pipeline_key, :number])
    |> check_constraint(:pipeline_key, name: :pipeline_key_known)
    |> check_constraint(:number, name: :number_positive)
    |> unique_constraint([:organisation_id, :pipeline_key, :number],
      name: :pipeline_versions_organisation_id_pipeline_key_number_index,
      error_key: :number,
      message: "was just saved by somebody else"
    )
  end
end
