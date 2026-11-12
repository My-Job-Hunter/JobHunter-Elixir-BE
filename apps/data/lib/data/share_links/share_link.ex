defmodule Data.ShareLinks.ShareLink do
  @moduledoc """
  A share link (AQ-03B §3.3, §4): one task, job or lead (AQ-04A QP4a-20), at a level
  (`Data.Vocabulary.share_levels/0`), for any signed-in staff member of the
  organisation who holds it. Only the token's SHA-256 is stored.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Jobs.Job
  alias Data.Leads.Lead
  alias Data.Organisations.Organisation
  alias Data.Tasks.Task

  @levels Data.Vocabulary.share_levels() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "share_links" do
    field(:level, Ecto.Enum, values: @levels)
    field(:token_sha256, :binary, redact: true)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:task, Task)
    belongs_to(:job, Job)
    belongs_to(:lead, Lead)
    belongs_to(:created_by_user, User)
    belongs_to(:revoked_by_user, User)

    timestamps()
  end

  @doc "The levels, as atoms, least first."
  def levels, do: @levels

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :organisation_id,
      :task_id,
      :job_id,
      :lead_id,
      :level,
      :token_sha256,
      :created_by_user_id,
      :expires_at
    ])
    |> validate_required([:organisation_id, :level, :token_sha256])
    |> check_constraint(:level, name: :level_known)
    |> check_constraint(:task_id, name: :one_subject, message: "needs exactly one subject")
    |> check_constraint(:token_sha256, name: :token_sha256_length)
    |> unique_constraint(:token_sha256)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:lead_id)
  end

  @doc "Turns the link off, by `user_id`, at `at`."
  def revoke_changeset(link, %DateTime{} = at, user_id) do
    change(link, revoked_at: at, revoked_by_user_id: user_id)
  end
end
