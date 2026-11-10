defmodule Data.Customers.Skill do
  @moduledoc """
  One entry of the skills vocabulary (JH-01 §4.3, QP1-4). The slug is what
  keeps "Node" and "Node.js" from both standing; the name is what the screen
  shows. Archived, never deleted: profiles point at it.
  """

  use Data.Schema

  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "skills" do
    field(:name, :string)
    field(:slug, :string)
    field(:category, :string)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)

    timestamps()
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:organisation_id, :name, :slug, :category])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> put_slug()
    |> validate_required([:organisation_id, :name, :slug, :category])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:category, min: 1, max: 40)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, message: "is not a slug")
    |> check_constraint(:name, name: :name_present)
    |> unique_constraint([:organisation_id, :slug],
      error_key: :name,
      message: "is already in the vocabulary"
    )
    |> foreign_key_constraint(:organisation_id)
  end

  defp put_slug(changeset) do
    case {get_change(changeset, :slug), get_change(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
      _given_or_unchanged -> changeset
    end
  end

  @doc ~S|"Node.js" → "node-js", "C#" → "c-sharp", "C++" → "c-plus-plus".|
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace("c++", "c-plus-plus")
    |> String.replace("c#", "c-sharp")
    |> String.replace("f#", "f-sharp")
    |> String.replace(".net", "dot-net")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
