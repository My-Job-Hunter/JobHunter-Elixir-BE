defmodule Data.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  @moduledoc """
  The skills vocabulary (AQ-01 §4.3, QP1-4): seeded by `aq.prod_seed`
  (about 120, by category) and extended by staff. Slugs are unique per
  organisation so "Node" and "Node.js" cannot both stand; a skill is
  archived, never deleted, because profiles point at it (restrict).
  """

  def change do
    create table(:skills, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:category, :string, null: false)
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(unique_index(:skills, [:organisation_id, :slug]))
    create(constraint(:skills, :name_present, check: "btrim(name) <> ''"))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON skills " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON skills"
    )
  end
end
