defmodule Data.Teams.TeamMember do
  @moduledoc """
  Who is in a team, as what (JH-01 §4.2). The roles are `Data.Vocabulary`'s
  `team_member_roles`, shared with the frontend word for word.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Teams.Team

  @roles Data.Vocabulary.team_member_roles() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "team_members" do
    field(:role, Ecto.Enum, values: @roles)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)

    belongs_to(:team, Team)
    belongs_to(:user, User)
  end

  @doc "The roles, as atoms, strongest first."
  def roles, do: @roles

  @doc "Whether a role may lead a team: a manager or a lead."
  @spec leads?(atom()) :: boolean()
  def leads?(role), do: role in [:manager, :lead]

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:team_id, :user_id, :role, :joined_at])
    |> validate_required([:team_id, :user_id, :role, :joined_at])
    |> check_constraint(:role, name: :role_known)
    |> unique_constraint([:team_id, :user_id],
      name: :team_members_open_index,
      message: "is already in the team"
    )
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:user_id)
  end
end
