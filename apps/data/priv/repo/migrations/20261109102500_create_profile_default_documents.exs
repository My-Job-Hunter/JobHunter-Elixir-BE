defmodule Data.Repo.Migrations.CreateProfileDefaultDocuments do
  use Ecto.Migration

  @moduledoc """
  A profile's default CV (AQ-01 §4.3 `default_document_id`), as a link
  table: `documents` points at `profiles`, so the column could not carry
  its foreign key inside `create_profiles`. One row per profile; the API
  still speaks `default_document_id`.

  The document going takes the default with it (delete_all), which is what
  "nilify" meant for the column.
  """

  def change do
    create table(:profile_default_documents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)

      add(:document_id, references(:documents, type: :uuid, on_delete: :delete_all), null: false)
    end

    create(unique_index(:profile_default_documents, [:profile_id]))
    create(index(:profile_default_documents, [:document_id]))
  end
end
