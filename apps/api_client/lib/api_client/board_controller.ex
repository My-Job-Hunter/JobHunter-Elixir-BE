defmodule ApiClient.BoardController do
  @moduledoc "The customer's board (AQ-02 §7.3, QP2-4): Waiting on you · With the team · Done."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks.Portal

  action_fallback ApiShared.FallbackController

  def show(conn, _params) do
    with {:ok, board} <- Portal.board(conn.assigns.scope, Clock.now()),
         do: json(conn, TasksJSON.portal_board(board))
  end
end
