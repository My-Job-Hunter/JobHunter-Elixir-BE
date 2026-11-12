defmodule Data.Tasks.Participant do
  @moduledoc """
  Somebody a task concerns (AQ-02 §5.1; mCart's): an assignee (`level`
  primary or secondary), a watcher, and whether they muted it — one row per
  person. Staff only.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_participants" do
    field(:level, Ecto.Enum, values: [:primary, :secondary])
    field(:is_watcher, :boolean, default: false)
    field(:is_muted, :boolean, default: false)

    belongs_to(:task, Task)
    belongs_to(:user, User)

    timestamps()
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:task_id, :user_id, :level, :is_watcher, :is_muted])
    |> validate_required([:task_id, :user_id])
    |> check_constraint(:level, name: :level_known)
    |> check_constraint(:level, name: :does_something)
    |> unique_constraint([:task_id, :user_id])
    |> unique_constraint(:level, name: :task_participants_one_primary, message: "has a primary")
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end
end
