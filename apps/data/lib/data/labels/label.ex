defmodule Data.Labels.Label do
  @moduledoc """
  A team's label for its leads (AQ-04B §5.1, §9, QP4b-17): a name, no
  colour, unique in the team by its normalised form.
  """

  use Data.Schema

  alias Data.Organisations.Organisation
  alias Data.Teams.Team

  @type t :: %__MODULE__{}

  schema "labels" do
    field(:name, :string)
    field(:name_normalized, :string)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)

    timestamps()
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:organisation_id, :team_id, :name])
    |> update_change(:name, &(&1 |> String.trim() |> String.replace(~r/\s+/u, " ")))
    |> validate_required([:organisation_id, :team_id, :name])
    |> validate_length(:name, max: 40)
    |> normalise()
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> unique_constraint(:name,
      name: :labels_team_id_name_normalized_index,
      message: "is already a label of this team"
    )
  end

  @doc ~S"""
  A label's name for comparison: trimmed, spaces folded, lower case.

      iex> Data.Labels.Label.normalize("  Priority   Client ")
      "priority client"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name),
    do: name |> String.trim() |> String.replace(~r/\s+/u, " ") |> String.downcase()

  defp normalise(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) -> put_change(changeset, :name_normalized, normalize(name))
      _none -> changeset
    end
  end
end
