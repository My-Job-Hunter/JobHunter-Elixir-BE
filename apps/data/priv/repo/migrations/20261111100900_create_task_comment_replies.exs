defmodule Data.Repo.Migrations.CreateTaskCommentReplies do
  use Ecto.Migration

  @moduledoc """
  Answers to a comment (AQ-02 §5.1; mCart's). **This table is the
  one-level rule**: a reply points at a comment, and nothing points at a
  reply. `task_id` is carried for the one-read notification set, as in
  mCart; it cannot drift, because a comment never moves between tasks.
  A reply to a staff-only comment is staff-only (`Core.Tasks.Comments`).
  """

  def change do
    create table(:task_comment_replies, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:comment_id, references(:task_comments, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:body, :text, null: false)
      add(:is_staff_only, :boolean, null: false, default: false)
      add(:edited_at, :timestamptz)
      add(:deleted_at, :timestamptz)

      timestamps()
    end

    create(constraint(:task_comment_replies, :body_present, check: "btrim(body) <> ''"))
    create(index(:task_comment_replies, [:comment_id, :inserted_at]))
    create(index(:task_comment_replies, [:task_id]))
    create(index(:task_comment_replies, [:author_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_comment_replies " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_comment_replies"
    )
  end
end
