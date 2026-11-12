defmodule Data.Pipelines.Stage do
  @moduledoc """
  A stage of one pipeline version (AQ-04A §5.1): a stable `key`, a `name`,
  an engine `kind` or `custom` with the engine kind it follows
  (`anchor_kind`), and its `position`. No colour: the kind is the colour.
  """

  use Data.Schema

  alias Data.Pipelines.Version

  @engine Data.Vocabulary.stage_kinds() |> Enum.map(&String.to_atom/1)
  @kinds @engine ++ [:custom]

  @type t :: %__MODULE__{}

  schema "pipeline_stages" do
    field(:key, :string)
    field(:name, :string)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:anchor_kind, Ecto.Enum, values: @engine)
    field(:position, :integer)

    belongs_to(:pipeline_version, Version)
  end

  @doc "The engine kinds, in the engine's order."
  def engine_kinds, do: @engine

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:pipeline_version_id, :key, :name, :kind, :anchor_kind, :position])
    |> validate_required([:pipeline_version_id, :key, :name, :kind, :position])
    |> check_constraint(:name, name: :name_present)
    |> check_constraint(:key, name: :key_slug)
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:anchor_kind, name: :anchor_kind_known)
    |> check_constraint(:anchor_kind, name: :custom_anchored)
  end
end
