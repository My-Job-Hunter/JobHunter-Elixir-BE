defmodule ApiTeam.StageController do
  @moduledoc "A person's own In progress stages (AQ-02 §7.2, QP2-10): `/me/stages`, answering `{stages, suggested}`."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Tasks.Stages

  action_fallback ApiShared.FallbackController

  def index(conn, _params), do: reply(conn, Stages.list(conn.assigns.scope))
  def create(conn, params), do: reply(conn, Stages.create(conn.assigns.scope, params))

  def update(conn, %{"id" => id} = params),
    do: reply(conn, Stages.rename(conn.assigns.scope, id, params))

  def delete(conn, %{"id" => id}), do: reply(conn, Stages.delete(conn.assigns.scope, id))
  def order(conn, params), do: reply(conn, Stages.reorder(conn.assigns.scope, params["ids"]))

  defp reply(conn, {:ok, stages}), do: json(conn, TasksJSON.stages(stages))
  defp reply(_conn, error), do: error
end
