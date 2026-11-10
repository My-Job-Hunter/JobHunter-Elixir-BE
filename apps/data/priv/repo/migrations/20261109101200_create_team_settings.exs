defmodule Data.Repo.Migrations.CreateTeamSettings do
  use Ecto.Migration

  @moduledoc """
  A team's six visibility toggles (JH-01 §4.2; PLAN §3.4), 1:1 with the team.
  Code defaults when no row; set by a lead or above.
  """

  def change do
    create table(:team_settings, primary_key: false) do
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:members_see_peer_tasks, :boolean, null: false, default: false)
      add(:members_see_peer_leads, :boolean, null: false, default: true)
      add(:members_move_peer_leads, :boolean, null: false, default: false)
      add(:customer_sees_staff_names, :boolean, null: false, default: true)
      add(:customer_sees_conversations, :boolean, null: false, default: true)
      add(:customer_sees_job_suggestions, :boolean, null: false, default: false)

      timestamps()
    end

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON team_settings " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON team_settings"
    )
  end
end
