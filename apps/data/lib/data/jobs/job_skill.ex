defmodule Data.Jobs.JobSkill do
  @moduledoc "A skill a job asks for (AQ-03 §5.1), required or nice to have."

  use Data.Schema

  alias Data.Customers.Skill
  alias Data.Jobs.Job

  @primary_key false

  @type t :: %__MODULE__{}

  schema "job_skills" do
    belongs_to(:job, Job, primary_key: true)
    belongs_to(:skill, Skill, primary_key: true)
    field(:is_required, :boolean, default: true)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:job_id, :skill_id, :is_required])
    |> validate_required([:job_id, :skill_id, :is_required])
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint([:job_id, :skill_id], name: :job_skills_pkey)
  end
end
