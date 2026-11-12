defmodule Data.Repo.Migrations.CreateTaskChecklistItems do
  use Ecto.Migration

  @moduledoc """
  A task's checklist (AQ-02 §5.1). `checked_at` and `checked_by_user_id`
  rather than mCart's `is_checked`: one fact, and who did it. Ticked by
  anyone who may move the task, and by the customer on a task given to them.
  """

  def change do
    create table(:task_checklist_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:position, :smallint, null: false, default: 0)
      add(:text, :string, null: false)
      add(:checked_at, :timestamptz)
      add(:checked_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:task_checklist_items, :text_present, check: "btrim(text) <> ''"))

    create(
      constraint(:task_checklist_items, :checked_by_only_when_checked,
        check: "checked_by_user_id IS NULL OR checked_at IS NOT NULL"
      )
    )

    create(index(:task_checklist_items, [:task_id, :position]))
    create(index(:task_checklist_items, [:checked_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_checklist_items " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_checklist_items"
    )
  end
end
