defmodule Data.Repo.Migrations.CreateJobDismissals do
  use Ecto.Migration

  @moduledoc """
  *Not for this profile* (AQ-03 §9, QP3-10): a suggestion hidden for one
  profile, with why. The reasons are kept for the AI phase (Q21); the job
  stays in the pool. One per job and profile; a merge moves them unless the
  survivor has its own.
  """

  def change do
    create table(:job_dismissals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:reason, :string, null: false)
      add(:note, :text)
      add(:dismissed_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:dismissed_at, :timestamptz, null: false)
    end

    create(
      constraint(:job_dismissals, :reason_known,
        check:
          "reason IN ('skills','money','location','seniority','company','already_known','other')"
      )
    )

    create(unique_index(:job_dismissals, [:job_id, :profile_id]))
    create(index(:job_dismissals, [:profile_id]))
    create(index(:job_dismissals, [:dismissed_by_user_id]))
  end
end
