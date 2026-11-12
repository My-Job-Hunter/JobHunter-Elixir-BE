defmodule Data.Jobs.Merge do
  @moduledoc """
  A merged job's key, link and title (AQ-03 §8, QP3-8), pointing at the job
  it was merged into, so its link resolves there, in that job's team's pool
  (AQ-03B §4).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Jobs.Job
  alias Data.Organisations.Organisation
  alias Data.Teams.Team

  @type t :: %__MODULE__{}

  schema "job_merges" do
    field(:from_canonical_key, :string)
    field(:from_source_url, :string)
    field(:from_title, :string)
    field(:merged_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:into_job, Job)
    belongs_to(:merged_by_user, User)
  end

  def changeset(merge, attrs) do
    merge
    |> cast(attrs, [
      :organisation_id,
      :team_id,
      :into_job_id,
      :from_canonical_key,
      :from_source_url,
      :from_title,
      :merged_by_user_id,
      :merged_at
    ])
    |> validate_required([
      :organisation_id,
      :team_id,
      :into_job_id,
      :from_canonical_key,
      :from_source_url,
      :from_title,
      :merged_at
    ])
    |> unique_constraint([:team_id, :from_canonical_key])
    |> foreign_key_constraint(:into_job_id)
  end
end
