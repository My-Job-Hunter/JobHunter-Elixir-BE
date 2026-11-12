defmodule Data.Repo.Migrations.CreateJobMerges do
  use Ecto.Migration

  @moduledoc """
  What a merge leaves behind (AQ-03 §8, QP3-8): the merged job is deleted,
  and its key, link and title are kept here, so **its link resolves to the
  survivor** (§6.3), in its team's pool (AQ-03B §4): `(team_id,
  from_canonical_key)` is unique, so a key is merged once per team. A
  later merge of the survivor re-points these rows, so every link merged
  into a job follows it.
  """

  def change do
    create table(:job_merges, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:into_job_id, references(:jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:from_canonical_key, :text, null: false)
      add(:from_source_url, :text, null: false)
      add(:from_title, :string, null: false)
      add(:merged_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:merged_at, :timestamptz, null: false)
    end

    create(unique_index(:job_merges, [:team_id, :from_canonical_key]))
    create(index(:job_merges, [:organisation_id]))
    create(index(:job_merges, [:into_job_id]))
    create(index(:job_merges, [:merged_by_user_id]))
  end
end
