defmodule Data.Repo.Migrations.CreateProfileSkills do
  use Ecto.Migration

  @moduledoc """
  A profile's skills with their level (AQ-01 §4.3). The skill is restricted
  from deletion while a profile names it — the vocabulary is archived, not
  pruned — and the pair is unique.
  """

  def change do
    create table(:profile_skills, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:skill_id, references(:skills, type: :uuid, on_delete: :restrict), null: false)
      add(:level, :string, null: false, default: "working")
      add(:years, :smallint)
    end

    create(
      constraint(:profile_skills, :level_known,
        check: "level IN ('familiar','working','strong','expert')"
      )
    )

    create(constraint(:profile_skills, :years_not_negative, check: "years IS NULL OR years >= 0"))
    create(unique_index(:profile_skills, [:profile_id, :skill_id]))
    create(index(:profile_skills, [:skill_id]))
  end
end
