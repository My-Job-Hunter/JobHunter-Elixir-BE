defmodule Data.Tasks.TaskMedia do
  @moduledoc "A file on a task (AQ-02 §5.1): an `attachment` from the three-step upload, in order."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Files.Media
  alias Data.Tasks.Task

  @primary_key false

  @type t :: %__MODULE__{}

  schema "task_media" do
    belongs_to(:task, Task, primary_key: true)
    belongs_to(:media, Media, primary_key: true)
    field(:position, :integer, default: 0)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:added_by_user, User)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:task_id, :media_id, :position, :added_by_user_id])
    |> validate_required([:task_id, :media_id])
    |> unique_constraint(:media_id, name: :task_media_pkey, message: "is already on this task")
    |> foreign_key_constraint(:media_id)
  end
end
