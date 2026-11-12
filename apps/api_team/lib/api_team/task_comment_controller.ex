defmodule ApiTeam.TaskCommentController do
  @moduledoc """
  A task's thread in the console (AQ-02 §7.2): read it, comment, reply
  (`{body, is_staff_only, mention_user_ids}`), and edit or delete one's own.
  Each answers the thread.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks.Comments

  action_fallback ApiShared.FallbackController

  def index(conn, %{"id" => id}), do: answer(conn, Comments.thread(conn.assigns.scope, id))

  def create(conn, %{"id" => id} = params),
    do: answer(conn, Comments.create(conn.assigns.scope, id, params, Clock.now()))

  def reply(conn, %{"id" => id, "comment_id" => comment_id} = params),
    do: answer(conn, Comments.reply(conn.assigns.scope, id, comment_id, params, Clock.now()))

  def update_comment(conn, %{"id" => id} = params),
    do: answer(conn, Comments.edit(conn.assigns.scope, :comment, id, params, Clock.now()))

  def delete_comment(conn, %{"id" => id}),
    do: answer(conn, Comments.delete(conn.assigns.scope, :comment, id, Clock.now()))

  def update_reply(conn, %{"id" => id} = params),
    do: answer(conn, Comments.edit(conn.assigns.scope, :reply, id, params, Clock.now()))

  def delete_reply(conn, %{"id" => id}),
    do: answer(conn, Comments.delete(conn.assigns.scope, :reply, id, Clock.now()))

  defp answer(conn, {:ok, thread}), do: json(conn, TasksJSON.thread(thread))
  defp answer(_conn, error), do: error
end
