defmodule Data.Teams.Team do
  @moduledoc "A team of the organisation (AQ-01 §4.2)."

  use Data.Schema

  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "teams" do
    field(:name, :string)
    field(:slug, :string)
    field(:archived_at, :utc_datetime_usec)
    # Filled by `Data.Teams.with_member_counts/1` for the list and the page.
    field(:member_count, :integer, virtual: true)

    belongs_to(:organisation, Organisation)

    timestamps()
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:organisation_id, :name, :slug])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> put_slug()
    |> validate_required([:organisation_id, :name, :slug])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, message: "is not a slug")
    |> check_constraint(:name, name: :name_present)
    |> unique_constraint([:organisation_id, :slug], message: "a team with that name exists")
    |> foreign_key_constraint(:organisation_id)
  end

  defp put_slug(changeset) do
    case {get_change(changeset, :slug), get_change(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(changeset, :slug, Organisation.slugify(name))

      _given_or_unchanged ->
        changeset
    end
  end
end
