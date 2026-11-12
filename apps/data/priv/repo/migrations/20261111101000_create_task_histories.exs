defmodule Data.Repo.Migrations.CreateTaskHistories do
  use Ecto.Migration

  @moduledoc """
  A task's activity (AQ-02 §5.1; mCart's): **one row per changed field**,
  the rows of one save sharing a `change_group_id`, the labels resolved and
  **frozen at write** — renaming a stage never rewrites what the log said.
  A log, never the state. Which rows the customer reads is decided by
  `field` on read (§6.4), never by a column here.
  """

  def change do
    create table(:task_histories, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:change_group_id, :uuid, null: false)
      add(:field, :string, null: false)
      add(:from_value, :text)
      add(:to_value, :text)
      add(:from_label, :string)
      add(:to_label, :string)
      add(:changed_at, :timestamptz, null: false)
    end

    create(
      constraint(:task_histories, :field_known,
        check:
          "field IN ('created','title','description','state','stage','priority','due','reminder'," <>
            "'team','customer','profile','customer_access','private','assignees','watchers'," <>
            "'checklist','step','link','relation','file','archived')"
      )
    )

    create(
      constraint(:task_histories, :something_changed,
        check: "from_value IS DISTINCT FROM to_value"
      )
    )

    create(index(:task_histories, [:task_id, :changed_at]))
    create(index(:task_histories, [:change_group_id]))
    create(index(:task_histories, [:actor_user_id]))
  end
end
