defmodule Data.Approvals.Approval do
  @moduledoc """
  An approval (AQ-07 §5.1): its kind, state, title and rule; what it is
  about (a lead, a profile, a conversation and the message a reply
  answers); due and auto-approve; who asked; `version_count`, the current
  version's number; and what approval did (`effect`, `effect_note`,
  `effect_at`). The verbs (`Core.Approvals.Act`) decide every column; this
  module casts and names the constraints.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Approvals.{Comment, Decision, Reviewer, Version}
  alias Data.Conversations.{Conversation, Message}
  alias Data.Customers.{Customer, Profile}
  alias Data.Leads.Lead
  alias Data.Organisations.Organisation
  alias Data.Teams.Team
  alias Data.Vocabulary

  @kinds Vocabulary.approval_kinds() |> Enum.map(&String.to_atom/1)
  @states Vocabulary.approval_states() |> Enum.map(&String.to_atom/1)
  @rules Vocabulary.approval_rules() |> Enum.map(&String.to_atom/1)
  @effects Vocabulary.approval_effects() |> Enum.map(&String.to_atom/1)

  @fields ~w(organisation_id team_id customer_id approval_kind state title lead_id profile_id
             message_id conversation_id rule due_at auto_approve_at requested_by_user_id
             submitted_at decided_at version_count effect effect_note effect_at)a

  @type t :: %__MODULE__{}

  schema "approvals" do
    field(:approval_kind, Ecto.Enum, values: @kinds)
    field(:state, Ecto.Enum, values: @states, default: :draft)
    field(:title, :string)
    field(:rule, Ecto.Enum, values: @rules, default: :any)
    field(:due_at, :utc_datetime_usec)
    field(:auto_approve_at, :utc_datetime_usec)
    field(:submitted_at, :utc_datetime_usec)
    field(:decided_at, :utc_datetime_usec)
    field(:version_count, :integer, default: 1)
    field(:effect, Ecto.Enum, values: @effects, default: :none)
    field(:effect_note, :string)
    field(:effect_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:customer, Customer)
    belongs_to(:lead, Lead)
    belongs_to(:profile, Profile)
    belongs_to(:message, Message)
    belongs_to(:conversation, Conversation)
    belongs_to(:requested_by_user, User)
    has_many(:versions, Version, preload_order: [asc: :number])
    has_many(:reviewers, Reviewer, preload_order: [asc: :position])
    has_many(:decisions, Decision, preload_order: [asc: :decided_at])
    has_many(:comments, Comment)

    timestamps()
  end

  @doc "Every column a write may set."
  def fields, do: @fields

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, @fields)
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([
      :organisation_id,
      :team_id,
      :customer_id,
      :approval_kind,
      :state,
      :title,
      :rule,
      :version_count
    ])
    |> validate_length(:title, max: 200)
    |> check_constraint(:approval_kind, name: :approval_kind_known)
    |> check_constraint(:state, name: :state_known)
    |> check_constraint(:rule, name: :rule_known)
    |> check_constraint(:effect, name: :effect_known)
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
    |> check_constraint(:lead_id,
      name: :subject_for_kind,
      message: "isn't what this kind is about"
    )
    |> check_constraint(:conversation_id, name: :thread_only_reply, message: "is for a reply")
    |> check_constraint(:submitted_at, name: :submitted_past_draft)
    |> check_constraint(:effect, name: :effect_once_approved)
    |> check_constraint(:effect_note, name: :failed_with_reason)
    |> foreign_key_constraint(:lead_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:conversation_id)
  end
end
