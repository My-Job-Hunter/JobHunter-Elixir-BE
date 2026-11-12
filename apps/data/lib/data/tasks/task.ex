defmodule Data.Tasks.Task do
  @moduledoc """
  A task on the board (AQ-02 §4, §5.1). Belongs to exactly one team, fixed
  at creation (AQ-03B §4, QT-12), may be about a customer and one of their
  profiles, and may be shown to or given to that customer
  (`customer_access`, QP2-2).

  Two changesets because two kinds of write: `changeset/2` for what a
  person sets (`PATCH /tasks/:id` and creation), `state_changeset/2` for
  what a verb moves (state and the columns each state holds). Who may do
  either is `Core.Access`'s; the CHECKs in the migration hold the shape.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.{Customer, Profile}
  alias Data.Organisations.Organisation
  alias Data.Tasks.{ChecklistItem, Link, Participant, Stage, Step, TaskMedia}
  alias Data.Teams.Team
  alias Data.Vocabulary

  @states Vocabulary.task_states() |> Enum.map(&String.to_atom/1)
  @priorities Vocabulary.task_priorities() |> Enum.map(&String.to_atom/1)
  @close_reasons Vocabulary.task_close_reasons() |> Enum.map(&String.to_atom/1)
  @access Vocabulary.task_customer_access() |> Enum.map(&String.to_atom/1)
  @sources Vocabulary.task_sources() |> Enum.map(&String.to_atom/1)

  @editable ~w(title description priority due_at due_on reminder_minutes customer_id profile_id
               customer_access)a

  @state_fields ~w(state stage_id held_at hold_reason held_from_state done_at done_by_user_id
                   closed_at closed_reason closed_note closed_by_user_id)a

  @type t :: %__MODULE__{}

  schema "tasks" do
    field(:source, Ecto.Enum, values: @sources, default: :staff)
    field(:title, :string)
    field(:description, :string)
    field(:state, Ecto.Enum, values: @states, default: :todo)
    field(:priority, Ecto.Enum, values: @priorities)
    field(:due_at, :utc_datetime_usec)
    field(:due_on, :date)
    field(:reminder_minutes, :integer)
    field(:customer_access, Ecto.Enum, values: @access, default: :none)
    field(:held_at, :utc_datetime_usec)
    field(:hold_reason, :string)
    field(:held_from_state, Ecto.Enum, values: [:todo, :in_progress])
    field(:done_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:closed_reason, Ecto.Enum, values: @close_reasons)
    field(:closed_note, :string)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:customer, Customer)
    belongs_to(:profile, Profile)
    belongs_to(:lead, Data.Leads.Lead)
    belongs_to(:author_user, User)
    belongs_to(:stage, Stage)
    belongs_to(:done_by_user, User)
    belongs_to(:closed_by_user, User)
    belongs_to(:archived_by_user, User)

    has_many(:participants, Participant)
    has_many(:steps, Step, preload_order: [asc: :position, asc: :id])
    has_many(:checklist_items, ChecklistItem, preload_order: [asc: :position, asc: :id])
    has_many(:links, Link, preload_order: [asc: :position, asc: :id])
    has_many(:task_media, TaskMedia, preload_order: [asc: :position, asc: :inserted_at])

    timestamps()
  end

  @doc "The states, as atoms, in board order."
  def states, do: @states

  @doc "What `PATCH /tasks/:id` may set."
  def editable_fields, do: @editable

  @doc "What a person sets: at creation (with the ids the context fixed) and on `PATCH`."
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :organisation_id,
      :team_id,
      :author_user_id,
      :source,
      :state,
      :lead_id | @editable
    ])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:organisation_id, :team_id, :title, :state, :customer_access, :source])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:reminder_minutes, Vocabulary.task_reminders(),
      message: "is not one of the reminder choices"
    )
    |> one_due()
    |> rules()
  end

  @doc "A verb's move: the state and the columns that go with it."
  def state_changeset(task, attrs) do
    task
    |> cast(attrs, @state_fields)
    |> validate_required([:state])
    |> rules()
  end

  @doc "Archive (`at`) or unarchive (`nil`)."
  def archive_changeset(task, at, user_id) do
    change(task, archived_at: at, archived_by_user_id: at && user_id)
  end

  # A due is a time or a day; the form says which one it dropped.
  defp one_due(changeset) do
    if get_field(changeset, :due_at) && get_field(changeset, :due_on),
      do: add_error(changeset, :due_on, "cannot be given with due_at"),
      else: changeset
  end

  defp rules(changeset) do
    changeset
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
    |> check_constraint(:source, name: :source_known)
    |> check_constraint(:state, name: :state_known)
    |> check_constraint(:priority, name: :priority_known)
    |> check_constraint(:customer_access, name: :customer_access_known)
    |> check_constraint(:closed_reason, name: :closed_reason_known)
    |> check_constraint(:held_from_state, name: :held_from_state_known)
    |> check_constraint(:reminder_minutes, name: :reminder_minutes_known)
    |> check_constraint(:due_on, name: :one_due, message: "cannot be given with due_at")
    |> check_constraint(:reminder_minutes,
      name: :reminder_needs_due_at,
      message: "needs a due time"
    )
    |> check_constraint(:customer_access,
      name: :customer_access_needs_customer,
      message: "needs a customer"
    )
    |> check_constraint(:profile_id, name: :profile_needs_customer, message: "needs a customer")
    |> check_constraint(:customer_access,
      name: :customer_source_shown,
      message: "the customer's own task is always shown to them"
    )
    |> check_constraint(:hold_reason, name: :hold_matches_state)
    |> check_constraint(:hold_reason, name: :hold_has_reason, message: "can't be blank")
    |> check_constraint(:hold_reason, name: :hold_fields_only_on_hold)
    |> check_constraint(:state, name: :done_matches_state)
    |> check_constraint(:closed_reason, name: :closed_matches_state, message: "can't be blank")
    |> check_constraint(:stage_id, name: :stage_only_in_progress, message: "only in progress")
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:stage_id)
    |> foreign_key_constraint(:lead_id)
  end
end
