defmodule ApiTeam.LeadController do
  @moduledoc """
  Leads in the console (AQ-04A §8.1): the board, a lead made (saved or
  applied, on a pool job or a new one), read and edited, and its verbs —
  each answering the sheet. Every move carries what the client saw,
  `from: {state, stage}`. P4b (AQ-04B §8.1): the History page, *Log
  follow-up*, the lead's labels and the bulk verbs. `Core.Leads.*` decides; `ApiShared.LeadsJSON`
  lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads
  alias Core.Leads.{Act, Board, Bulk, Change, FollowUp, History, Labels}

  action_fallback ApiShared.FallbackController

  def board(conn, params) do
    with {:ok, board} <- Board.show(conn.assigns.scope, params, Clock.now()),
         do: json(conn, LeadsJSON.board(board))
  end

  def create(conn, params) do
    with {:ok, sheet} <- Leads.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(LeadsJSON.sheet(sheet))
    end
  end

  def show(conn, %{"id" => id}), do: sheet(conn, Leads.get(conn.assigns.scope, id, Clock.now()))

  def update(conn, %{"id" => id} = params),
    do: sheet(conn, Change.edit(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()))

  for verb <- ~w(apply apply_again move hold resume finish reopen)a do
    def unquote(verb)(conn, %{"id" => id} = params),
      do: sheet(conn, Act.run(conn.assigns.scope, unquote(verb), id, params, Clock.now()))
  end

  for verb <- ~w(archive unarchive pin unpin)a do
    def unquote(verb)(conn, %{"id" => id}),
      do: sheet(conn, Change.flag(conn.assigns.scope, unquote(verb), id, Clock.now()))
  end

  def assign(conn, %{"id" => id} = params),
    do: sheet(conn, Change.assign(conn.assigns.scope, id, params, Clock.now()))

  def cv(conn, %{"id" => id} = params),
    do: sheet(conn, Change.cv(conn.assigns.scope, id, params, Clock.now()))

  def pipeline(conn, %{"id" => id} = params),
    do: sheet(conn, Change.pipeline(conn.assigns.scope, id, params, Clock.now()))

  # ── AQ-04B §8.1 ─────────────────────────────────────────────────────────────

  def history(conn, %{"id" => id} = params) do
    with {:ok, page} <- History.page(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, LeadsJSON.history(page))
  end

  def follow_up(conn, %{"id" => id} = params),
    do: sheet(conn, FollowUp.log(conn.assigns.scope, id, params, Clock.now()))

  def labels(conn, %{"id" => id} = params),
    do: sheet(conn, Labels.put_on_lead(conn.assigns.scope, id, params, Clock.now()))

  def bulk(conn, params) do
    with {:ok, result} <- Bulk.run(conn.assigns.scope, params, Clock.now()) do
      refused =
        Enum.map(result.refused, fn %{id: id, reason: reason} ->
          Map.put(ApiShared.FallbackController.describe(reason), :id, id)
        end)

      json(conn, LeadsJSON.bulk(%{done: result.done, refused: refused}))
    end
  end

  defp sheet(conn, {:ok, sheet}), do: json(conn, LeadsJSON.sheet(sheet))
  defp sheet(_conn, error), do: error
end
