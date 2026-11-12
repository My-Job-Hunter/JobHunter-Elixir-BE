defmodule Data.Repo.Migrations.CreateJobUpworkDetails do
  use Ecto.Migration

  @moduledoc """
  What Upwork shows about a job and its client (AQ-03 §5.2, QP3-4), one row
  per job at most. `experience_level` is mapped onto `jobs.seniority` by
  `Core.Jobs` when the job has none. The client's average hourly rate is
  minor units with its currency (CONVENTIONS §3).
  """

  def change do
    create table(:job_upwork_details, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:experience_level, :string)
      add(:connects_required, :smallint)
      add(:is_client_payment_verified, :boolean)
      add(:client_rating, :numeric, precision: 3, scale: 2)
      add(:client_reviews, :integer)
      add(:client_country, :string)
      add(:client_city, :string)
      add(:client_timezone, :string)
      add(:client_jobs_posted, :integer)
      add(:client_hire_rate_pct, :smallint)
      add(:client_open_jobs, :smallint)
      add(:client_spent_band, :string)
      add(:client_hires, :integer)
      add(:client_active_hires, :integer)
      add(:client_avg_hourly_minor, :bigint)
      add(:client_avg_hourly_currency, :string)
      add(:client_member_since_on, :date)

      timestamps()
    end

    create(
      constraint(:job_upwork_details, :experience_level_known,
        check: "experience_level IS NULL OR experience_level IN ('entry','intermediate','expert')"
      )
    )

    create(
      constraint(:job_upwork_details, :client_spent_band_known,
        check:
          "client_spent_band IS NULL OR client_spent_band IN ('none','lt_1k','1k_10k'," <>
            "'10k_100k','100k_1m','gt_1m')"
      )
    )

    create(
      constraint(:job_upwork_details, :client_country_iso,
        check: "client_country IS NULL OR client_country ~ '^[A-Z]{2}$'"
      )
    )

    create(
      constraint(:job_upwork_details, :client_rating_range,
        check: "client_rating IS NULL OR client_rating BETWEEN 0 AND 5"
      )
    )

    create(
      constraint(:job_upwork_details, :client_hire_rate_pct_range,
        check: "client_hire_rate_pct IS NULL OR client_hire_rate_pct BETWEEN 0 AND 100"
      )
    )

    create(
      constraint(:job_upwork_details, :client_avg_hourly_whole,
        check: "client_avg_hourly_minor IS NULL OR client_avg_hourly_currency ~ '^[A-Z]{3}$'"
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON job_upwork_details " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON job_upwork_details"
    )
  end
end
