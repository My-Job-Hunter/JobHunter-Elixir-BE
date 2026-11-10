defmodule Data.Repo.Migrations.CreateOrganisations do
  use Ecto.Migration

  @moduledoc """
  The organisation (JH-01 §4.2): one today (PLAN Q1), and every business row
  carries its id. `timezone` is the day boundary; `currency_code` is for
  reporting. Made by `mix jh.bootstrap`, never by a seed.
  """

  def change do
    create table(:organisations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:country_code, :string)
      add(:timezone, :string, null: false, default: "Asia/Karachi")
      add(:currency_code, :string, null: false, default: "USD")

      timestamps()
    end

    create(unique_index(:organisations, [:slug]))
    create(constraint(:organisations, :name_present, check: "btrim(name) <> ''"))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON organisations " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON organisations"
    )
  end
end
