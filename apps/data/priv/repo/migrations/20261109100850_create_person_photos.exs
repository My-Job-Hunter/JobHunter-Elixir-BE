defmodule Data.Repo.Migrations.CreatePersonPhotos do
  use Ecto.Migration

  @moduledoc """
  A person's photo (JH-01 §4.1): the link between `persons` and `media`,
  one row per person. **One link table per owner** (AutoCare's pattern,
  `document_media` in §4.3) rather than a `photo_media_id` column, because
  `media` points at `users` which points at `persons`: a column could not
  carry its foreign key inside `create_persons`.

  A person going takes the link with it; a `media` row that is somebody's
  photo cannot be deleted (restrict) — the link is removed first.
  """

  def change do
    create table(:person_photos, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:person_id, references(:persons, type: :uuid, on_delete: :delete_all), null: false)
      add(:media_id, references(:media, type: :uuid, on_delete: :restrict), null: false)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(unique_index(:person_photos, [:person_id]))
    create(index(:person_photos, [:media_id]))
  end
end
