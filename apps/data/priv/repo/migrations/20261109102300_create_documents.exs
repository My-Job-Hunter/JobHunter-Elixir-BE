defmodule Data.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  @moduledoc """
  A profile's documents (JH-01 §4.3): CVs, cover-letter templates,
  portfolio links, certificates. **A CV is one row per version**: a new
  version is a new row with `version_no + 1` that `supersedes` the old one,
  so a lead sent "Golang v4" keeps pointing at v4.

  A document has a file (`document_media`, the next migration) **or** a
  `url` — the CHECK on `url` is one half of that rule; the other half (a
  url-less row must get a `document_media` link) is `Core.Customers.Documents`'s.
  """

  def change do
    create table(:documents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:label, :string, null: false)
      add(:version_no, :smallint, null: false, default: 1)

      add(
        :supersedes_document_id,
        references(:documents, type: :uuid, on_delete: :nilify_all)
      )

      add(:url, :string)
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:documents, :kind_known,
        check: "kind IN ('cv','cover_letter_template','portfolio','certificate','other')"
      )
    )

    create(constraint(:documents, :label_present, check: "btrim(label) <> ''"))
    create(constraint(:documents, :version_no_positive, check: "version_no >= 1"))

    create(constraint(:documents, :url_shape, check: "url IS NULL OR url ~ '^https?://'"))

    create(unique_index(:documents, [:profile_id, :label, :version_no]))
    create(index(:documents, [:supersedes_document_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON documents " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON documents"
    )
  end
end
