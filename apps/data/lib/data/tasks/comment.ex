defmodule Data.Tasks.Comment do
  @moduledoc """
  A comment on a task (AQ-02 §5.1): for the team only (`is_staff_only`) or
  seen by the customer. A delete keeps the row, so its replies keep their
  place.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.{Reply, Task}

  @type t :: %__MODULE__{}

  schema "task_comments" do
    field(:body, :string)
    field(:is_staff_only, :boolean, default: false)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:task, Task)
    belongs_to(:author_user, User)
    has_many(:replies, Reply, foreign_key: :comment_id, preload_order: [asc: :inserted_at])

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:task_id, :author_user_id, :body, :is_staff_only])
    |> validate_required([:task_id, :body])
    |> validate_length(:body, max: 20_000)
    |> check_constraint(:body, name: :body_present, message: "can't be blank")
    |> foreign_key_constraint(:task_id)
  end
end
