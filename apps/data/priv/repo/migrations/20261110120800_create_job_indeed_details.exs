defmodule Data.Repo.Migrations.CreateJobIndeedDetails do
  use Ecto.Migration

  @moduledoc """
  What Indeed shows about a job (AQ-03 §5.2, QP3-4), one row per job at
  most: its badges and the work setting as written.
  """

  def change do
    create table(:job_indeed_details, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:is_easily_apply, :boolean)
      add(:is_responsive_employer, :boolean)
      add(:is_urgently_hiring, :boolean)
      add(:work_setting_text, :string)

      timestamps()
    end

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON job_indeed_details " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON job_indeed_details"
    )
  end
end
