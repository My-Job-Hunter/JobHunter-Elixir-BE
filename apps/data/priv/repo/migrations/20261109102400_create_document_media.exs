defmodule Data.Repo.Migrations.CreateDocumentMedia do
  use Ecto.Migration

  @moduledoc """
  A document's file (JH-01 §4.3): the link between `documents` and `media`,
  one per document (unique `document_id`). One link table per owner
  (AutoCare's pattern), so `media` knows nothing about what it illustrates.
  The file cannot be deleted while a document points at it (restrict).
  """

  def change do
    create table(:document_media, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:document_id, references(:documents, type: :uuid, on_delete: :delete_all), null: false)

      add(:media_id, references(:media, type: :uuid, on_delete: :restrict), null: false)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(unique_index(:document_media, [:document_id]))
    create(index(:document_media, [:media_id]))
  end
end
