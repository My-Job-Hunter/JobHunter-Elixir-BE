defmodule ApiTeam.TaskPartController do
  @moduledoc """
  A task's parts in the console (AQ-02 §7.2): the checklist, the steps (with
  *Nudge*), links, relations and files. Each answers the sheet.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks.{Checklist, Files, Links, Steps}

  action_fallback ApiShared.FallbackController

  def add_item(conn, %{"id" => id} = params),
    do: reply(conn, Checklist.add(scope(conn), id, params, Clock.now()))

  def rename_item(conn, %{"id" => id, "item_id" => item_id} = params),
    do: reply(conn, Checklist.rename(scope(conn), id, item_id, params, Clock.now()))

  def toggle_item(conn, %{"id" => id, "item_id" => item_id}),
    do: reply(conn, Checklist.toggle(scope(conn), id, item_id, Clock.now()))

  def remove_item(conn, %{"id" => id, "item_id" => item_id}),
    do: reply(conn, Checklist.remove(scope(conn), id, item_id, Clock.now()))

  def order_items(conn, %{"id" => id} = params),
    do: reply(conn, Checklist.reorder(scope(conn), id, params["ids"], Clock.now()))

  def add_step(conn, %{"id" => id} = params),
    do: reply(conn, Steps.add(scope(conn), id, params, Clock.now()))

  def update_step(conn, %{"id" => id, "step_id" => step_id} = params),
    do: reply(conn, Steps.update(scope(conn), id, step_id, params, Clock.now()))

  def toggle_step(conn, %{"id" => id, "step_id" => step_id}),
    do: reply(conn, Steps.toggle(scope(conn), id, step_id, Clock.now()))

  def nudge_step(conn, %{"id" => id, "step_id" => step_id}),
    do: reply(conn, Steps.nudge(scope(conn), id, step_id, Clock.now()))

  def remove_step(conn, %{"id" => id, "step_id" => step_id}),
    do: reply(conn, Steps.remove(scope(conn), id, step_id, Clock.now()))

  def order_steps(conn, %{"id" => id} = params),
    do: reply(conn, Steps.reorder(scope(conn), id, params["ids"], Clock.now()))

  def add_link(conn, %{"id" => id} = params),
    do: reply(conn, Links.add_link(scope(conn), id, params, Clock.now()))

  def remove_link(conn, %{"id" => id, "link_id" => link_id}),
    do: reply(conn, Links.remove_link(scope(conn), id, link_id, Clock.now()))

  def add_relation(conn, %{"id" => id} = params),
    do: reply(conn, Links.add_relation(scope(conn), id, params, Clock.now()))

  def remove_relation(conn, %{"id" => id, "relation_id" => relation_id}),
    do: reply(conn, Links.remove_relation(scope(conn), id, relation_id, Clock.now()))

  def add_file(conn, %{"id" => id} = params),
    do: reply(conn, Files.add(scope(conn), id, params, Clock.now()))

  def remove_file(conn, %{"id" => id, "media_id" => media_id}),
    do: reply(conn, Files.remove(scope(conn), id, media_id, Clock.now()))

  defp scope(conn), do: conn.assigns.scope

  defp reply(conn, {:ok, sheet}), do: TasksJSON.send_sheet(conn, sheet)
  defp reply(_conn, error), do: error
end
