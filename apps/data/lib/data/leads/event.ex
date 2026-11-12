defmodule Data.Leads.Event do
  @moduledoc """
  One row of a lead's ledger (AQ-04A §5.2): append-only, written in the
  verb's transaction. Frozen words (`from_label`, `to_label`), an outcome,
  a note, the CV of a `cv_set`, `is_again` on an apply-again; P4b (AQ-04B
  §5.3) the task of a `task_created` or `task_done` and the note of a
  `note_added`; AQ-06 §5.4 the message, meeting, contact or conversation
  of P6's kinds; AQ-07 §5.4 the approval of P7's — at most one key
  (`one_ref`). AQ-05 §10.4: `request_id`,
  the extension's queued write that made it, unique.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Document
  alias Data.Leads.Lead
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @kinds Vocabulary.lead_event_kinds() |> Enum.map(&String.to_atom/1)
  @actors Vocabulary.event_actors() |> Enum.map(&String.to_atom/1)
  @visibilities Vocabulary.event_visibilities() |> Enum.map(&String.to_atom/1)
  @outcomes Vocabulary.lead_outcomes() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "lead_events" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:occurred_at, :utc_datetime_usec)
    field(:recorded_at, :utc_datetime_usec)
    field(:actor_kind, Ecto.Enum, values: @actors)
    field(:visibility, Ecto.Enum, values: @visibilities)
    field(:from_label, :string)
    field(:to_label, :string)
    field(:outcome, Ecto.Enum, values: @outcomes)
    field(:note, :string)
    field(:is_again, :boolean, default: false)
    field(:request_id, Ecto.UUID)

    belongs_to(:organisation, Organisation)
    belongs_to(:lead, Lead)
    belongs_to(:actor_user, User)
    belongs_to(:document, Document)
    belongs_to(:task, Data.Tasks.Task)
    belongs_to(:lead_note, Data.Leads.Note, foreign_key: :note_id)
    belongs_to(:message, Data.Conversations.Message)
    belongs_to(:meeting, Data.Meetings.Meeting)
    belongs_to(:contact, Data.Contacts.Contact)
    belongs_to(:conversation, Data.Conversations.Conversation)
    belongs_to(:approval, Data.Approvals.Approval)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :organisation_id,
      :lead_id,
      :kind,
      :occurred_at,
      :recorded_at,
      :actor_kind,
      :actor_user_id,
      :visibility,
      :from_label,
      :to_label,
      :outcome,
      :note,
      :document_id,
      :task_id,
      :note_id,
      :message_id,
      :meeting_id,
      :contact_id,
      :conversation_id,
      :approval_id,
      :is_again,
      :request_id
    ])
    |> validate_required([
      :organisation_id,
      :lead_id,
      :kind,
      :occurred_at,
      :recorded_at,
      :actor_kind,
      :visibility
    ])
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:actor_kind, name: :actor_kind_known)
    |> check_constraint(:visibility, name: :visibility_known)
    |> check_constraint(:outcome, name: :outcome_known)
    |> check_constraint(:actor_user_id, name: :actor_user_with_person)
    |> check_constraint(:note, name: :note_with_reason)
    |> check_constraint(:is_again, name: :again_only_applied)
    |> check_constraint(:task_id, name: :one_ref)
    |> unique_constraint(:request_id, name: :lead_events_request_id_index)
  end
end
