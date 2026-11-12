defmodule Data.Tasks.Stage do
  @moduledoc "A person's own In progress stage (AQ-02 §5.1, QP2-10): *Sourcing*, *Preparing*."

  use Data.Schema

  alias Data.Accounts.User

  @type t :: %__MODULE__{}

  schema "task_stages" do
    field(:name, :string)
    field(:position, :integer, default: 0)
    # Filled by `Data.TaskStages.list/1`: how many tasks wear it now.
    field(:in_use, :integer, virtual: true, default: 0)

    belongs_to(:user, User)

    timestamps()
  end

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:user_id, :name, :position])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> unique_constraint(:name,
      name: :task_stages_user_id_name_index,
      message: "is already one of your stages"
    )
    |> foreign_key_constraint(:user_id)
  end
end
