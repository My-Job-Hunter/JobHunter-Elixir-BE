defmodule Data.Tasks.Reply do
  @moduledoc """
  An answer to a comment (AQ-02 §5.1): one level by construction. Carries
  `task_id` for the one-read notification set, as in mCart.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.{Comment, Task}

  @type t :: %__MODULE__{}

  schema "task_comment_replies" do
    field(:body, :string)
    field(:is_staff_only, :boolean, default: false)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:comment, Comment)
    belongs_to(:task, Task)
    belongs_to(:author_user, User)

    timestamps()
  end

  def changeset(reply, attrs) do
    reply
    |> cast(attrs, [:comment_id, :task_id, :author_user_id, :body, :is_staff_only])
    |> validate_required([:comment_id, :task_id, :body])
    |> validate_length(:body, max: 20_000)
    |> check_constraint(:body, name: :body_present, message: "can't be blank")
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:task_id)
  end
end
