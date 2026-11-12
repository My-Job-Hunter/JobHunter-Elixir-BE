defmodule Data.Repo.Migrations.CreateTaskMedia do
  use Ecto.Migration

  @moduledoc """
  A task's files (AQ-02 §5.1; mCart's): `media` rows of kind
  `attachment`, put on the task after the three-step upload, in order, with
  who added each — staff and the customer both add files.
  """

  def change do
    create table(:task_media, primary_key: false) do
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:media_id, references(:media, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:position, :smallint, null: false, default: 0)
      add(:added_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(constraint(:task_media, :position_not_negative, check: "position >= 0"))
    create(index(:task_media, [:media_id]))
    create(index(:task_media, [:added_by_user_id]))
  end
end
