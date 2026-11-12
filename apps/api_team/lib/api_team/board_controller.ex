defmodule ApiTeam.BoardController do
  @moduledoc "The console's board page (AQ-02 §7.2, AQ-03B §5.1): `GET /board?team_id&mine&watching&customer_id&…`."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks.Board

  action_fallback ApiShared.FallbackController

  def show(conn, params) do
    with {:ok, page} <- Board.page(conn.assigns.scope, params, Clock.now()),
         do: json(conn, TasksJSON.board(page))
  end
end
