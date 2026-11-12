defmodule Data.Repo.Migrations.CreateJobLinkedinDetails do
  use Ecto.Migration

  @moduledoc """
  What LinkedIn shows about a job (AQ-03 §5.2, QP3-4), one row per job at
  most. Only what the page shows; what moves by the hour waits for
  `job_signals` (P5, QP3-5).
  """

  def change do
    create table(:job_linkedin_details, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:is_easy_apply, :boolean)
      add(:applicant_count, :smallint)
      # "Over 100": the count is a floor, not a number.
      add(:is_applicant_count_capped, :boolean)
      add(:is_promoted, :boolean)
      add(:is_early_applicant, :boolean)
      add(:experience_level_text, :string)
      add(:employment_status_text, :string)
      add(:hiring_team_text, :text)

      timestamps()
    end

    create(
      constraint(:job_linkedin_details, :applicant_count_not_negative,
        check: "applicant_count IS NULL OR applicant_count >= 0"
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON job_linkedin_details " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON job_linkedin_details"
    )
  end
end
