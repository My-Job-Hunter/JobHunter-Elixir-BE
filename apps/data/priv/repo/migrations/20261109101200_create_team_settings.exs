defmodule Data.Repo.Migrations.CreateTeamSettings do
  use Ecto.Migration

  @moduledoc """
  A team's settings (AQ-01 §4.2; PLAN §3.4; AQ-03B §4), 1:1 with the team:
  what a member sees and does with a teammate's tasks, leads and jobs
  (`peer_*` ∈ `hidden · view · edit`, QT-4's defaults), and what the customer
  sees. Code defaults when no row; set by a lead or above.
  """

  def change do
    create table(:team_settings, primary_key: false) do
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:peer_tasks, :text, null: false, default: "view")
      add(:peer_leads, :text, null: false, default: "view")
      add(:peer_jobs, :text, null: false, default: "edit")
      add(:customer_sees_staff_names, :boolean, null: false, default: true)
      add(:customer_sees_conversations, :boolean, null: false, default: true)
      add(:customer_sees_job_suggestions, :boolean, null: false, default: false)

      timestamps()
    end

    # `Data.Vocabulary.peer_access/0`, word for word.
    create(
      constraint(:team_settings, :peer_tasks_known,
        check: "peer_tasks IN ('hidden','view','edit')"
      )
    )

    create(
      constraint(:team_settings, :peer_leads_known,
        check: "peer_leads IN ('hidden','view','edit')"
      )
    )

    create(
      constraint(:team_settings, :peer_jobs_known, check: "peer_jobs IN ('hidden','view','edit')")
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON team_settings " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON team_settings"
    )
  end
end
