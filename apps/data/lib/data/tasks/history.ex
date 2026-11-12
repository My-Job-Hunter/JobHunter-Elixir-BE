defmodule Data.Tasks.History do
  @moduledoc """
  One changed field of a task (AQ-02 §5.1; mCart's): values as stored,
  labels as they read on the day, grouped by `change_group_id`.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task

  @fields Data.Vocabulary.task_history_fields() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "task_histories" do
    field(:change_group_id, Ecto.UUID)
    field(:field, Ecto.Enum, values: @fields)
    field(:from_value, :string)
    field(:to_value, :string)
    field(:from_label, :string)
    field(:to_label, :string)
    field(:changed_at, :utc_datetime_usec)

    belongs_to(:task, Task)
    belongs_to(:actor_user, User)
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :task_id,
      :actor_user_id,
      :change_group_id,
      :field,
      :from_value,
      :to_value,
      :from_label,
      :to_label,
      :changed_at
    ])
    |> validate_required([:task_id, :change_group_id, :field, :changed_at])
    |> check_constraint(:field, name: :field_known)
    |> check_constraint(:to_value, name: :something_changed)
  end
end
