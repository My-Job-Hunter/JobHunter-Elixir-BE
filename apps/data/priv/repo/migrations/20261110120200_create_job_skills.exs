defmodule Data.Repo.Migrations.CreateJobSkills do
  use Ecto.Migration

  @moduledoc """
  A job's skills (AQ-03 §5.1), from P1's vocabulary: required or nice to
  have (`is_required`), which the suggestion score weighs (§9). The pair is
  the key; the skill is restricted from deletion while a job names it — the
  vocabulary is archived, never pruned.
  """

  def change do
    create table(:job_skills, primary_key: false) do
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:skill_id, references(:skills, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false
      )

      add(:is_required, :boolean, null: false, default: true)
    end

    create(index(:job_skills, [:skill_id]))
  end
end
