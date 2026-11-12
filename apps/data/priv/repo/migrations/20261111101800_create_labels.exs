defmodule Data.Repo.Migrations.CreateLabels do
  use Ecto.Migration

  @moduledoc """
  A team's labels for its leads (AQ-04B §5.1, §9, QP4b-17): named, **no
  colour** (neutral chips: colour keeps meaning one thing), unique per team
  by their normalised name. Made, renamed and removed by the team's leads
  and the system admin; put on a lead through `lead_labels`.
  """

  def change do
    create table(:labels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:name, :text, null: false)
      add(:name_normalized, :text, null: false)

      timestamps()
    end

    create(
      constraint(:labels, :name_present, check: "btrim(name) <> '' AND char_length(name) <= 40")
    )

    create(unique_index(:labels, [:team_id, :name_normalized]))
    create(index(:labels, [:organisation_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON labels " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON labels"
    )
  end
end
