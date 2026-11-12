defmodule Data.Repo.Migrations.CreateTaskParticipants do
  use Ecto.Migration

  @moduledoc """
  The staff a task concerns (AQ-02 §5.1; mCart's): who is doing it
  (`level` primary or secondary), who only wants to be told (`is_watcher`),
  and who asked not to be (`is_muted`), in one row per person. A watcher is
  not given work: `level IS NULL` keeps them off their own board (QP2-16).

  **Staff only.** The customer's part is `tasks.customer_access` (QP2-2);
  `Core.Tasks` refuses a customer's account here.
  """

  def change do
    create table(:task_participants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:level, :string)
      add(:is_watcher, :boolean, null: false, default: false)
      add(:is_muted, :boolean, null: false, default: false)

      timestamps()
    end

    create(
      constraint(:task_participants, :level_known,
        check: "level IS NULL OR level IN ('primary','secondary')"
      )
    )

    # A row that neither assigns, watches nor mutes says nothing.
    create(
      constraint(:task_participants, :does_something,
        check: "level IS NOT NULL OR is_watcher OR is_muted"
      )
    )

    create(unique_index(:task_participants, [:task_id, :user_id]))

    # Exactly one primary is the database's to hold, not a changeset's hope.
    create(
      unique_index(:task_participants, [:task_id],
        where: "level = 'primary'",
        name: :task_participants_one_primary
      )
    )

    create(
      index(:task_participants, [:user_id],
        where: "level IS NOT NULL",
        name: :task_participants_assigned_index
      )
    )

    create(
      index(:task_participants, [:user_id],
        where: "is_watcher",
        name: :task_participants_watching_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_participants " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_participants"
    )
  end
end
