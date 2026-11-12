defmodule Data.Leads.Lead do
  @moduledoc """
  One profile's application to one job (AQ-04A §5.2). In its job's team;
  one per `(job, profile)`. Four states, a stage of its own pipeline
  version while In progress (kept on hold and in Done), the application's
  facts as columns, and the flags that keep it (`is_pinned`, `archived_at`).
  Every verb's columns are `Core.Leads.Act`'s to decide; this module casts
  and names the constraints.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.{Document, Profile}
  alias Data.Jobs.Job
  alias Data.Leads.Event
  alias Data.Organisations.Organisation
  alias Data.Pipelines.{Stage, Version}
  alias Data.Vocabulary

  @states Vocabulary.lead_states() |> Enum.map(&String.to_atom/1)
  @priorities Vocabulary.lead_priorities() |> Enum.map(&String.to_atom/1)
  @methods Vocabulary.apply_methods() |> Enum.map(&String.to_atom/1)
  @confirmations Vocabulary.lead_confirmations() |> Enum.map(&String.to_atom/1)
  @bid_periods Vocabulary.bid_periods() |> Enum.map(&String.to_atom/1)
  @periods Vocabulary.comp_periods() |> Enum.map(&String.to_atom/1)
  @outcomes Vocabulary.lead_outcomes() |> Enum.map(&String.to_atom/1)
  @archive_reasons Vocabulary.lead_archive_reasons() |> Enum.map(&String.to_atom/1)

  @fields ~w(organisation_id job_id profile_id owner_user_id created_by_user_id state
             pipeline_version_id stage_id priority applied_at applied_by_user_id applied_via
             applied_confirmation document_id cover_letter_md bid_minor bid_currency bid_period
             connects_spent expectation_minor expectation_currency expectation_period held_at
             hold_reason hold_until_on outcome outcome_note finished_at is_pinned
             last_activity_at archived_at archived_by_user_id archive_reason)a

  @type t :: %__MODULE__{}

  schema "leads" do
    field(:state, Ecto.Enum, values: @states, default: :todo)
    field(:priority, Ecto.Enum, values: @priorities)
    field(:applied_at, :utc_datetime_usec)
    field(:applied_via, Ecto.Enum, values: @methods)
    field(:applied_confirmation, Ecto.Enum, values: @confirmations)
    field(:cover_letter_md, :string)
    field(:bid_minor, :integer)
    field(:bid_currency, :string)
    field(:bid_period, Ecto.Enum, values: @bid_periods)
    field(:connects_spent, :integer)
    field(:expectation_minor, :integer)
    field(:expectation_currency, :string)
    field(:expectation_period, Ecto.Enum, values: @periods)
    field(:held_at, :utc_datetime_usec)
    field(:hold_reason, :string)
    field(:hold_until_on, :date)
    field(:outcome, Ecto.Enum, values: @outcomes)
    field(:outcome_note, :string)
    field(:finished_at, :utc_datetime_usec)
    field(:is_pinned, :boolean, default: false)
    field(:last_activity_at, :utc_datetime_usec)
    field(:archived_at, :utc_datetime_usec)
    field(:archive_reason, Ecto.Enum, values: @archive_reasons)

    belongs_to(:organisation, Organisation)
    belongs_to(:job, Job)
    belongs_to(:profile, Profile)
    belongs_to(:owner_user, User)
    belongs_to(:created_by_user, User)
    belongs_to(:pipeline_version, Version)
    belongs_to(:stage, Stage)
    belongs_to(:applied_by_user, User)
    belongs_to(:document, Document)
    belongs_to(:archived_by_user, User)
    has_many(:events, Event)

    timestamps()
  end

  @doc "Every column a write may set."
  def fields, do: @fields

  @doc "The states, in their order."
  def states, do: @states

  def changeset(lead, attrs) do
    lead
    |> cast(attrs, @fields)
    |> validate_required([
      :organisation_id,
      :job_id,
      :profile_id,
      :owner_user_id,
      :state,
      :pipeline_version_id,
      :last_activity_at
    ])
    |> validate_length(:cover_letter_md, max: 20_000)
    |> validate_length(:hold_reason, max: 1000)
    |> validate_length(:outcome_note, max: 2000)
    |> validate_number(:connects_spent, greater_than_or_equal_to: 0, less_than: 32_768)
    |> validate_number(:bid_minor, greater_than_or_equal_to: 0)
    |> validate_number(:expectation_minor, greater_than_or_equal_to: 0)
    |> validate_format(:bid_currency, ~r/^[A-Z]{3}$/, message: "is not an ISO currency code")
    |> validate_format(:expectation_currency, ~r/^[A-Z]{3}$/,
      message: "is not an ISO currency code"
    )
    |> validate_money(:bid)
    |> validate_money(:expectation)
    |> unique_constraint([:job_id, :profile_id],
      name: :leads_job_id_profile_id_index,
      error_key: :profile_id,
      message: "already has a lead on this job"
    )
    |> check_constraint(:state, name: :state_known)
    |> check_constraint(:priority, name: :priority_known)
    |> check_constraint(:applied_via, name: :applied_via_known)
    |> check_constraint(:applied_confirmation, name: :applied_confirmation_known)
    |> check_constraint(:bid_period, name: :bid_period_known)
    |> check_constraint(:expectation_period, name: :expectation_period_known)
    |> check_constraint(:outcome, name: :outcome_known)
    |> check_constraint(:archive_reason, name: :archive_reason_known)
    |> check_constraint(:stage_id, name: :stage_once_applied)
    |> check_constraint(:applied_at, name: :applied_past_todo)
    |> check_constraint(:hold_reason, name: :held_with_reason)
    |> check_constraint(:hold_until_on, name: :hold_until_on_hold)
    |> check_constraint(:outcome, name: :done_with_outcome)
    |> check_constraint(:bid_minor, name: :bid_together)
    |> check_constraint(:expectation_minor, name: :expectation_together)
    |> check_constraint(:archived_at, name: :archived_together)
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:document_id)
  end

  # An amount, its currency and its period together, or none of them.
  defp validate_money(changeset, money) do
    parts = [:"#{money}_minor", :"#{money}_currency", :"#{money}_period"]
    set = Enum.reject(parts, &is_nil(get_field(changeset, &1)))

    if set == [] or length(set) == 3,
      do: changeset,
      else:
        Enum.reduce(parts -- set, changeset, fn field, acc ->
          add_error(acc, field, "is needed with the rest of the #{money}")
        end)
  end
end
