defmodule Data.Repo.Migrations.CreateTaskStages do
  use Ecto.Migration

  @moduledoc """
  A person's own In progress stages (AQ-02 §5.1, QP2-10; mCart's D45):
  *Sourcing*, *Waiting on the customer*. A task In progress may carry one of
  its primary assignee's stages; nobody has to. Removing a stage clears it
  from the tasks that used it (`tasks.stage_id` nilifies) and nothing else.
  """

  def change do
    create table(:task_stages, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:position, :smallint, null: false, default: 0)

      timestamps()
    end

    create(constraint(:task_stages, :name_present, check: "btrim(name) <> ''"))
    create(constraint(:task_stages, :position_not_negative, check: "position >= 0"))

    create(
      unique_index(:task_stages, [:user_id, "lower(name)"], name: :task_stages_user_id_name_index)
    )

    create(index(:task_stages, [:user_id, :position]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_stages " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_stages"
    )
  end
end
