defmodule Data.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  @moduledoc """
  A team of the organisation (JH-01 §4.2): Backend squad, Frontend squad.
  Archived, never deleted: its members' history stays readable.
  """

  def change do
    create table(:teams, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(unique_index(:teams, [:organisation_id, :slug]))
    create(constraint(:teams, :name_present, check: "btrim(name) <> ''"))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON teams " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON teams"
    )
  end
end
