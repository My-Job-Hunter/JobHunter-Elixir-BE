defmodule Data.Repo.Migrations.CreateTaskLinks do
  use Ecto.Migration

  @moduledoc """
  Web links on a task (AQ-02 §5.1): **http and https only**, through
  `Utils.SafeUrl` on the way in and a CHECK here, so a `javascript:` link
  never reaches storage. Removed by delete; the history keeps that it was
  there.
  """

  def change do
    create table(:task_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), null: false)
      add(:url, :text, null: false)
      add(:label, :string)
      add(:position, :smallint, null: false, default: 0)
      add(:added_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:task_links, :url_shape, check: "url ~ '^https?://'"))
    create(unique_index(:task_links, [:task_id, :url]))
    create(index(:task_links, [:task_id, :position]))
    create(index(:task_links, [:added_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON task_links " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON task_links"
    )
  end
end
