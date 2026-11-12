defmodule Data.Repo.Migrations.CreateTaskComments do
  use Ecto.Migration

  @moduledoc """
  Comments on a task (AQ-02 §5.1; mCart's). Each is **for the team only**
  (`is_staff_only`) or seen by the customer; a customer never writes a
  staff-only one (`Core.Tasks.Comments`). Replies are their own table (the
  next-but-one migration), so a reply to a reply has nowhere to be stored.
  A delete keeps the row (`deleted_at`) so the replies keep their context.
  """

  def change do
    create table(:task_comments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:body, :text, null: false)
      add(:is_staff_only, :boolean, null: false, default: false)
      add(:edited_at, :timestamptz)
      add(:deleted_at, :timestamptz)

      timestamps()
    end

    create(constraint(:task_comments, :body_present, check: "btrim(body) <> ''"))
    create(index(:task_comments, [:task_id, :inserted_at]))
    create(index(:task_comments, [:author_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_comments " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_comments"
    )
  end
end
