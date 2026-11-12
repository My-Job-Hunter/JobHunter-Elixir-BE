defmodule Data.Tasks.Step do
  @moduledoc """
  A step of a task (AQ-02 §5.1, QP2-1): a title, one assignee (a staff
  person or the customer) and a tick.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_steps" do
    field(:position, :integer, default: 0)
    field(:title, :string)
    field(:is_for_customer, :boolean, default: false)
    field(:done_at, :utc_datetime_usec)

    belongs_to(:task, Task)
    belongs_to(:assignee_user, User)
    belongs_to(:done_by_user, User)

    timestamps()
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:task_id, :position, :title, :assignee_user_id, :is_for_customer])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:task_id, :title])
    |> validate_length(:title, min: 1, max: 200)
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
    |> check_constraint(:is_for_customer,
      name: :one_assignee,
      message: "a step is for a staff person or the customer, not both"
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:assignee_user_id)
  end

  @doc "Ticked (`at`, `by`) or unticked (`nil`)."
  def tick_changeset(step, at, user_id),
    do: change(step, done_at: at, done_by_user_id: at && user_id)
end
