defmodule Data.TaskComments do
  @moduledoc """
  A task's thread (AQ-02 §5.1): comments and their replies. Storage only;
  `Core.Tasks.Comments` decides who reads which (the customer never a
  staff-only one) and who writes. A delete keeps the row.
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Tasks.{Comment, Reply}

  @person [person: :photo]

  @doc "The thread, oldest first; `staff_only: false` leaves out every staff-only comment and reply."
  @spec thread(binary(), keyword()) :: [Comment.t()]
  def thread(task_id, opts \\ []) do
    staff? = Keyword.get(opts, :staff_only, true)

    replies =
      from(r in Reply,
        order_by: [asc: r.inserted_at, asc: r.id],
        preload: ^[author_user: @person]
      )

    replies = if staff?, do: replies, else: where(replies, [r], not r.is_staff_only)

    from(c in Comment,
      where: c.task_id == ^task_id,
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [author_user: ^@person, replies: ^replies]
    )
    |> then(&if(staff?, do: &1, else: where(&1, [c], not c.is_staff_only)))
    |> Repo.all()
  end

  @doc "A comment of the task, or `nil`."
  @spec get_comment(binary(), term()) :: Comment.t() | nil
  def get_comment(task_id, id), do: get(Comment, [task_id: task_id], id)

  @doc "A comment by id, whatever its task, or `nil`: `PATCH /task-comments/:id`."
  @spec get_comment(term()) :: Comment.t() | nil
  def get_comment(id), do: get(Comment, [], id)

  @doc "A reply by id, or `nil`: `PATCH /task-replies/:id`."
  @spec get_reply(term()) :: Reply.t() | nil
  def get_reply(id), do: get(Reply, [], id)

  defp get(schema, clauses, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(schema, [{:id, uuid} | clauses])
      :error -> nil
    end
  end

  @spec create_comment(map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_comment(attrs), do: %Comment{} |> Comment.changeset(attrs) |> Repo.insert()

  @spec create_reply(map()) :: {:ok, Reply.t()} | {:error, Ecto.Changeset.t()}
  def create_reply(attrs), do: %Reply{} |> Reply.changeset(attrs) |> Repo.insert()

  @doc "A new body, stamped `edited_at`."
  @spec edit(Comment.t() | Reply.t(), String.t() | nil, DateTime.t()) ::
          {:ok, Comment.t() | Reply.t()} | {:error, Ecto.Changeset.t()}
  def edit(%schema{} = row, body, %DateTime{} = at) do
    row
    |> schema.changeset(%{body: body})
    |> Ecto.Changeset.put_change(:edited_at, at)
    |> Repo.update()
  end

  @doc "Marks it deleted; the row stays so the thread keeps its shape."
  @spec soft_delete(Comment.t() | Reply.t(), DateTime.t()) :: Comment.t() | Reply.t()
  def soft_delete(row, %DateTime{} = at),
    do: row |> Ecto.Changeset.change(deleted_at: at) |> Repo.update!()
end
