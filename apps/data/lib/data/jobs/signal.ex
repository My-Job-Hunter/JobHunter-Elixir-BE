defmodule Data.Jobs.Signal do
  @moduledoc """
  What moved on a posting when the extension saw it (AQ-05 §5.3, QP5-14):
  applicants, proposals, interviews, invites, hires and when the client
  last looked. Written only when a fact differs from the job's latest row.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Jobs.Job
  alias Data.Organisations.Organisation

  @facts ~w(applicant_count is_applicant_count_capped proposals_min proposals_max interviewing
            invites_sent unanswered_invites hires client_last_viewed_at)a
  @counts ~w(applicant_count proposals_min proposals_max interviewing invites_sent
             unanswered_invites hires)a

  @type t :: %__MODULE__{}

  schema "job_signals" do
    field(:observed_at, :utc_datetime_usec)
    field(:applicant_count, :integer)
    field(:is_applicant_count_capped, :boolean)
    field(:proposals_min, :integer)
    field(:proposals_max, :integer)
    field(:interviewing, :integer)
    field(:invites_sent, :integer)
    field(:unanswered_invites, :integer)
    field(:hires, :integer)
    field(:client_last_viewed_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:job, Job)
    belongs_to(:observed_by_user, User)
  end

  @doc "The facts a row holds, the ones compared with the latest row."
  def facts, do: @facts

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [:organisation_id, :job_id, :observed_at, :observed_by_user_id | @facts])
    |> validate_required([:organisation_id, :job_id, :observed_at])
    |> then(fn cs ->
      Enum.reduce(@counts, cs, fn field, acc ->
        validate_number(acc, field, greater_than_or_equal_to: 0, less_than: 32_768)
      end)
    end)
    |> validate_range()
    |> validate_a_fact()
    |> check_constraint(:proposals_min, name: :proposals_range)
    |> check_constraint(:applicant_count, name: :a_fact_is_set, message: "needs one fact")
    |> foreign_key_constraint(:job_id)
  end

  # The CHECKs, asked first, so a capture never meets them mid-transaction.
  defp validate_range(changeset) do
    case {get_field(changeset, :proposals_min), get_field(changeset, :proposals_max)} do
      {min, max} when is_integer(min) and is_integer(max) and min > max ->
        add_error(changeset, :proposals_min, "is more than proposals_max")

      _ordered ->
        changeset
    end
  end

  defp validate_a_fact(changeset) do
    facts = @facts -- [:is_applicant_count_capped]

    if Enum.all?(facts, &is_nil(get_field(changeset, &1))),
      do: add_error(changeset, :applicant_count, "needs one fact"),
      else: changeset
  end
end
