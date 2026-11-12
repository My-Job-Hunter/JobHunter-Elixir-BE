defmodule Data.Tasks.Relation do
  @moduledoc "Two tasks linked (AQ-02 §5.1): blocks · relates to · duplicates, read from both ends."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task

  @kinds Data.Vocabulary.task_relation_kinds() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "task_relations" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:from_task, Task)
    belongs_to(:to_task, Task)
    belongs_to(:created_by_user, User)
  end

  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:from_task_id, :to_task_id, :kind, :created_by_user_id])
    |> validate_required([:from_task_id, :to_task_id, :kind])
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:task_id, name: :no_self_relation, message: "is this task")
    |> unique_constraint(:task_id,
      name: :task_relations_from_task_id_to_task_id_kind_index,
      message: "is already related this way"
    )
    |> unique_constraint(:task_id,
      name: :task_relations_one_symmetric_pair,
      message: "is already related this way"
    )
    |> foreign_key_constraint(:to_task_id)
  end
end
