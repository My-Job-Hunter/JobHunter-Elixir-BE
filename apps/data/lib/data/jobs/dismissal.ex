defmodule Data.Jobs.Dismissal do
  @moduledoc "*Not for this profile* (AQ-03 §9): a suggestion hidden for one profile, with why."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Profile
  alias Data.Jobs.Job
  alias Data.Vocabulary

  @reasons Vocabulary.job_dismiss_reasons() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "job_dismissals" do
    field(:reason, Ecto.Enum, values: @reasons)
    field(:note, :string)
    field(:dismissed_at, :utc_datetime_usec)

    belongs_to(:job, Job)
    belongs_to(:profile, Profile)
    belongs_to(:dismissed_by_user, User)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:job_id, :profile_id, :reason, :note, :dismissed_by_user_id, :dismissed_at])
    |> validate_required([:job_id, :profile_id, :reason, :dismissed_at])
    |> validate_length(:note, max: 2000)
    |> check_constraint(:reason, name: :reason_known)
    |> unique_constraint([:job_id, :profile_id], error_key: :profile_id)
    |> foreign_key_constraint(:profile_id)
  end
end
