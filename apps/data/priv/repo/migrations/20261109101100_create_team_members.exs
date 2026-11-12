defmodule Data.Repo.Migrations.CreateTeamMembers do
  use Ecto.Migration

  @moduledoc """
  Who is in a team, as what (AQ-01 §4.2; PLAN §3.1): a **team lead** or
  **staff** (`member`). AQ-04A §4.0 removed the manager role: what a manager
  did is the team lead's in their team and the system admin's anywhere.

  One open membership per person per team (partial unique on `left_at IS
  NULL`); leaving sets `left_at` and the row stays. A team keeps at least one
  lead while it has members — a guard in `Core.Organisation`.
  """

  def change do
    create table(:team_members, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)
      add(:joined_at, :timestamptz, null: false)
      add(:left_at, :timestamptz)
    end

    create(constraint(:team_members, :role_known, check: "role IN ('lead','member')"))

    create(
      unique_index(:team_members, [:team_id, :user_id],
        where: "left_at IS NULL",
        name: :team_members_open_index
      )
    )

    create(index(:team_members, [:user_id]))
  end
end
