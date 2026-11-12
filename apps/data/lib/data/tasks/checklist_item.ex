defmodule Data.Tasks.ChecklistItem do
  @moduledoc "A line of a task's checklist (AQ-02 §5.1): the text, and who ticked it when."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_checklist_items" do
    field(:position, :integer, default: 0)
    field(:text, :string)
    field(:checked_at, :utc_datetime_usec)

    belongs_to(:task, Task)
    belongs_to(:checked_by_user, User)

    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:task_id, :position, :text])
    |> update_change(:text, &(&1 && String.trim(&1)))
    |> validate_required([:task_id, :text])
    |> validate_length(:text, min: 1, max: 255)
    |> check_constraint(:text, name: :text_present, message: "can't be blank")
    |> foreign_key_constraint(:task_id)
  end

  @doc "Ticked (`at`, `by`) or unticked (`nil`)."
  def tick_changeset(item, at, user_id),
    do: change(item, checked_at: at, checked_by_user_id: at && user_id)
end
