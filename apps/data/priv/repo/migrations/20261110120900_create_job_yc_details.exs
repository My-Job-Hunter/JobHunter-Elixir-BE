defmodule Data.Repo.Migrations.CreateJobYcDetails do
  use Ecto.Migration

  @moduledoc """
  What Work at a Startup shows about a job (AQ-03 §5.2, QP3-4), one row per
  job at most: the company's YC batch (`W24`), its size and stage, the
  experience asked for.
  """

  def change do
    create table(:job_yc_details, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:batch, :string)
      add(:team_size, :integer)
      add(:stage_text, :string)
      add(:experience_text, :string)

      timestamps()
    end

    create(
      constraint(:job_yc_details, :batch_shape,
        check: "batch IS NULL OR batch ~ '^[WSFX][0-9]{2}$'"
      )
    )

    create(
      constraint(:job_yc_details, :team_size_positive,
        check: "team_size IS NULL OR team_size >= 1"
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON job_yc_details " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON job_yc_details"
    )
  end
end
