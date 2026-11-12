defmodule Data.Repo.Migrations.CreateTaskRelations do
  use Ecto.Migration

  @moduledoc """
  Tasks linked to each other (AQ-02 §5.1; mCart's): blocks · relates to ·
  duplicates. **One row, read from both ends**: `blocks` reads *is blocked
  by* from the other side, and `relates_to` is its own inverse, so the
  symmetric unique index holds one row per pair whichever way it was made.
  Informational: a blocked task can still move (mCart §5b). Both ends in
  the same organisation is `Core.Tasks`'s to check.
  """

  def change do
    create table(:task_relations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:from_task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:to_task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:task_relations, :kind_known,
        check: "kind IN ('relates_to','blocks','duplicates')"
      )
    )

    create(constraint(:task_relations, :no_self_relation, check: "from_task_id <> to_task_id"))
    create(unique_index(:task_relations, [:from_task_id, :to_task_id, :kind]))

    create(
      unique_index(
        :task_relations,
        ["LEAST(from_task_id, to_task_id)", "GREATEST(from_task_id, to_task_id)"],
        where: "kind = 'relates_to'",
        name: :task_relations_one_symmetric_pair
      )
    )

    create(index(:task_relations, [:from_task_id]))
    create(index(:task_relations, [:to_task_id]))
    create(index(:task_relations, [:created_by_user_id]))
  end
end
