defmodule ApiClient.TaskController do
  @moduledoc """
  A task in the portal (AQ-02 §7.3), on the scope pinned to the customer:
  add one (routed by §9), read and edit their own while To do, *Mark done*,
  *Reopen*, *Withdraw* (`{from}`), tick what is theirs, add a file, the
  customer-visible thread and the activity of §6.4. The same `Core.Tasks.*`
  functions as the console; `Core.Access` decides what the customer may.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks
  alias Core.Tasks.{Act, Checklist, Comments, Files, Portal, Steps}

  action_fallback ApiShared.FallbackController

  def create(conn, params) do
    with {:ok, sheet} <-
           Portal.create(
             scope(conn),
             Map.take(params, ~w(title description profile_id due_on)),
             Clock.now()
           ) do
      conn |> put_status(:created) |> TasksJSON.send_portal_sheet(sheet)
    end
  end

  def show(conn, %{"id" => id}), do: sheet(conn, Tasks.get(scope(conn), id, Clock.now()))

  def update(conn, %{"id" => id} = params),
    do: sheet(conn, Portal.update(scope(conn), id, params, Clock.now()))

  def done(conn, %{"id" => id} = params),
    do: sheet(conn, Act.portal(scope(conn), :done, id, params, Clock.now()))

  def reopen(conn, %{"id" => id} = params),
    do: sheet(conn, Act.portal(scope(conn), :reopen, id, params, Clock.now()))

  def withdraw(conn, %{"id" => id} = params),
    do: sheet(conn, Act.portal(scope(conn), :withdraw, id, params, Clock.now()))

  def toggle_item(conn, %{"id" => id, "item_id" => item_id}),
    do: sheet(conn, Checklist.toggle(scope(conn), id, item_id, Clock.now()))

  def toggle_step(conn, %{"id" => id, "step_id" => step_id}),
    do: sheet(conn, Steps.toggle(scope(conn), id, step_id, Clock.now()))

  def add_file(conn, %{"id" => id} = params),
    do: sheet(conn, Files.add(scope(conn), id, params, Clock.now()))

  def history(conn, %{"id" => id}) do
    with {:ok, groups} <- Tasks.history(scope(conn), id),
         do: json(conn, TasksJSON.history(groups))
  end

  def comments(conn, %{"id" => id}), do: thread(conn, Comments.thread(scope(conn), id))

  # The customer writes `{body}` only: never a staff-only comment, never a mention.
  def comment(conn, %{"id" => id} = params),
    do: thread(conn, Comments.create(scope(conn), id, Map.take(params, ["body"]), Clock.now()))

  def reply(conn, %{"id" => id, "comment_id" => comment_id} = params),
    do:
      thread(
        conn,
        Comments.reply(scope(conn), id, comment_id, Map.take(params, ["body"]), Clock.now())
      )

  def update_comment(conn, %{"id" => id} = params),
    do: thread(conn, Comments.edit(scope(conn), :comment, id, params, Clock.now()))

  def delete_comment(conn, %{"id" => id}),
    do: thread(conn, Comments.delete(scope(conn), :comment, id, Clock.now()))

  def update_reply(conn, %{"id" => id} = params),
    do: thread(conn, Comments.edit(scope(conn), :reply, id, params, Clock.now()))

  def delete_reply(conn, %{"id" => id}),
    do: thread(conn, Comments.delete(scope(conn), :reply, id, Clock.now()))

  defp scope(conn), do: conn.assigns.scope

  defp sheet(conn, {:ok, sheet}), do: TasksJSON.send_portal_sheet(conn, sheet)
  defp sheet(_conn, error), do: error

  defp thread(conn, {:ok, thread}), do: json(conn, TasksJSON.thread(thread))
  defp thread(_conn, error), do: error
end
