defmodule Data.Repo.Migrations.CreateTaskSteps do
  use Ecto.Migration

  @moduledoc """
  A task's steps (AQ-02 §5.1, QP2-1): **a table of their own**, one level by
  construction — mCart's argument for replies, applied to steps. Each has
  one assignee: a staff person (`assignee_user_id`) or the customer
  (`is_for_customer`), never both. A step for the customer needs a task
  with a customer; `Core.Tasks.Steps` says so in words.
  """

  def change do
    create table(:task_steps, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:position, :smallint, null: false, default: 0)
      add(:title, :string, null: false)
      add(:assignee_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:is_for_customer, :boolean, null: false, default: false)
      add(:done_at, :timestamptz)
      add(:done_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:task_steps, :title_present, check: "btrim(title) <> ''"))

    create(
      constraint(:task_steps, :one_assignee,
        check: "NOT (assignee_user_id IS NOT NULL AND is_for_customer)"
      )
    )

    create(
      constraint(:task_steps, :done_by_only_when_done,
        check: "done_by_user_id IS NULL OR done_at IS NOT NULL"
      )
    )

    create(index(:task_steps, [:task_id, :position]))

    # *My steps* on My board.
    create(
      index(:task_steps, [:assignee_user_id],
        where: "done_at IS NULL",
        name: :task_steps_open_assignee_index
      )
    )

    create(index(:task_steps, [:done_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_steps " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_steps"
    )
  end
end
