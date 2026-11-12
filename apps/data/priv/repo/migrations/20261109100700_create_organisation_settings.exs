defmodule Data.Repo.Migrations.CreateOrganisationSettings do
  use Ecto.Migration

  @moduledoc """
  The prototype's timings as data (AQ-01 §4.2; PLAN §6.7, §6.8, §10.5), 1:1
  with the organisation. Code defaults when no row; every value is checked
  into 1–365 days.
  """

  @days ~w(follow_up_gap_days max_follow_ups no_response_days similar_window_days
           inactivity_days purge_after_days warning_days observation_retention_days)

  def change do
    create table(:organisation_settings, primary_key: false) do
      add(
        :organisation_id,
        references(:organisations, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:follow_up_gap_days, :integer, null: false, default: 3)
      add(:max_follow_ups, :integer, null: false, default: 2)
      add(:no_response_days, :integer, null: false, default: 14)
      add(:similar_window_days, :integer, null: false, default: 14)
      add(:inactivity_days, :integer, null: false, default: 90)
      add(:purge_after_days, :integer, null: false, default: 90)
      add(:warning_days, :integer, null: false, default: 7)
      add(:observation_retention_days, :integer, null: false, default: 180)

      timestamps()
    end

    for column <- @days do
      create(
        constraint(:organisation_settings, :"#{column}_in_range",
          check: "#{column} BETWEEN 1 AND 365"
        )
      )
    end

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON organisation_settings " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON organisation_settings"
    )
  end
end
