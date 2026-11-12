defmodule Core.Tasks.Comments do
  @moduledoc """
  A task's thread (AQ-02 §7.2, §7.3; mCart's): comments and one level of
  replies, each **for the team only** or seen by the customer. Staff choose
  (`is_staff_only`; Team only when they do not say, QP2-5); the customer
  never writes one, never reads one, and is never told of one. A reply to
  a staff-only comment is staff-only.

  Mentions are `mention_user_ids` — staff who may read the task; anyone
  else is ignored — and a mentioned person gets *mentioned*, not also
  *commented*. Only an author edits or deletes their own; a delete keeps
  the row so the replies keep their place. Comments write no history.
  """

  alias Core.Access
  alias Core.Realtime
  alias Core.Tasks
  alias Core.Tasks.{Histories, Notices, Person, Write}
  alias Data.Scope
  alias Data.TaskComments
  alias Data.Tasks.Comment

  @own_words "You can only change your own comment."

  @doc "`GET /tasks/:id/comments`: the thread the caller may read, oldest first."
  @spec thread(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def thread(%Scope{} = scope, id) do
    with {:ok, task} <- Tasks.fetch(scope, :read, id), do: {:ok, view(scope, task)}
  end

  @doc "`POST /tasks/:id/comments {body, is_staff_only, mention_user_ids}`. Answers the thread."
  @spec create(Scope.t(), term(), map(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def create(%Scope{} = scope, id, params, %DateTime{} = _now) do
    params = Tasks.stringify(params)

    with {:ok, task} <- Tasks.fetch(scope, :comment, id),
         {:ok, staff_only?} <- staff_only(scope, task, params, false) do
      attrs = %{
        task_id: task.id,
        author_user_id: Scope.user_id(scope),
        body: params["body"],
        is_staff_only: staff_only?
      }

      post(scope, task, :comment, params, fn -> TaskComments.create_comment(attrs) end)
    end
  end

  @doc "`POST /tasks/:id/comments/:comment_id/replies {body, is_staff_only, mention_user_ids}`."
  @spec reply(Scope.t(), term(), term(), map(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def reply(%Scope{} = scope, id, comment_id, params, %DateTime{} = _now) do
    params = Tasks.stringify(params)

    with {:ok, task} <- Tasks.fetch(scope, :comment, id),
         %Comment{deleted_at: nil} = comment <-
           TaskComments.get_comment(task.id, comment_id) || {:error, :not_found},
         :ok <- readable(scope, comment),
         {:ok, staff_only?} <- staff_only(scope, task, params, comment.is_staff_only) do
      attrs = %{
        comment_id: comment.id,
        task_id: task.id,
        author_user_id: Scope.user_id(scope),
        body: params["body"],
        is_staff_only: staff_only?
      }

      post(scope, task, :reply, params, fn -> TaskComments.create_reply(attrs) end)
    else
      %Comment{} -> {:error, :not_found}
      error -> error
    end
  end

  @doc "`PATCH /task-comments/:id` or `/task-replies/:id` (`kind` `:comment` or `:reply`) `{body}`: the author's own."
  @spec edit(Scope.t(), :comment | :reply, term(), map(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def edit(%Scope{} = scope, kind, id, params, %DateTime{} = now) do
    body = Tasks.stringify(params)["body"]

    with {:ok, task, row} <- own(scope, kind, id),
         {:ok, _edited} <- Write.commit(fn -> edited(task, TaskComments.edit(row, body, now)) end),
         do: {:ok, view(scope, task)}
  end

  defp edited(task, {:ok, row}), do: {:ok, row, events(task, row)}
  defp edited(_task, error), do: error

  @doc "`DELETE /task-comments/:id` or `/task-replies/:id`: marked deleted, kept in place."
  @spec delete(Scope.t(), :comment | :reply, term(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def delete(%Scope{} = scope, kind, id, %DateTime{} = now) do
    with {:ok, task, row} <- own(scope, kind, id),
         {:ok, _gone} <-
           Write.commit(fn -> {:ok, row, events(task, TaskComments.soft_delete(row, now))} end),
         do: {:ok, view(scope, task)}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Staff say which (Team only unless they say otherwise, QP2-5); a reply to
  # a staff-only comment is one; the customer never writes one.
  defp staff_only(scope, task, params, parent_staff_only?) do
    cond do
      Scope.customer?(scope) ->
        {:ok, false}

      parent_staff_only? ->
        {:ok, true}

      params["is_staff_only"] in [false, "false"] ->
        {:ok, false}

      true ->
        with :ok <- Access.why_not(scope, :comment_staff_only, {:task, task}), do: {:ok, true}
    end
  end

  defp post(scope, task, kind, params, insert) do
    mentions =
      if Scope.customer?(scope),
        do: [],
        else: Notices.mentionable(scope, task, params["mention_user_ids"])

    result =
      Write.commit(fn ->
        with {:ok, row} <- insert.() do
          {:ok, row, [Notices.commented(scope, task, row, kind, mentions), events(task, row)]}
        end
      end)

    with {:ok, _row} <- result,
         do: {:ok, view(scope, Tasks.fetch(scope, :read, task.id) |> elem(1))}
  end

  # The card's comment count moved; the customer's board hears only of what it may read.
  defp events(task, row),
    do: Realtime.task_events("task_updated", task, task, customer: not row.is_staff_only)

  defp own(scope, kind, id) do
    row = if kind == :comment, do: TaskComments.get_comment(id), else: TaskComments.get_reply(id)

    with %{deleted_at: nil} = row <- row || {:error, :not_found},
         {:ok, task} <- Tasks.fetch(scope, :read, row.task_id),
         :ok <- readable(scope, row),
         true <- row.author_user_id == Scope.user_id(scope) || {:error, {:forbidden, @own_words}} do
      {:ok, task, row}
    else
      %{deleted_at: %DateTime{}} -> {:error, :not_found}
      error -> error
    end
  end

  defp readable(scope, row) do
    if Scope.customer?(scope) and row.is_staff_only, do: {:error, :not_found}, else: :ok
  end

  defp view(scope, task) do
    customer? = Scope.customer?(scope)
    rows = TaskComments.thread(task.id, staff_only: not customer?)
    names? = Histories.names?(task)
    me = Scope.user_id(scope)

    author = fn user ->
      if customer?,
        do: Person.for_customer(user, task.customer, names?),
        else: Person.view(user, customer: task.customer)
    end

    entry = fn row ->
      %{
        id: row.id,
        author: author.(row.author_user),
        body: if(row.deleted_at, do: "", else: row.body),
        is_staff_only: row.is_staff_only,
        edited_at: row.edited_at,
        deleted: not is_nil(row.deleted_at),
        inserted_at: row.inserted_at,
        mine: row.author_user_id == me
      }
    end

    Enum.map(rows, &Map.put(entry.(&1), :replies, Enum.map(&1.replies, entry)))
  end
end
