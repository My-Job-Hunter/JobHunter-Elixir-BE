defmodule ApiTeam.TrackerController do
  @moduledoc """
  The Tracker (AQ-04B §8.1): `GET /tracker?team_id&…` (a keyset page of
  rows with the total) and `GET /tracker.csv?…the same…` (every row, every
  column, UTF-8 with a BOM, audited). `Core.Leads.Tracker` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads.Tracker

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Tracker.page(conn.assigns.scope, params, Clock.now()),
         do: json(conn, LeadsJSON.tracker(page))
  end

  def csv(conn, params) do
    with {:ok, body, filename} <- Tracker.csv(conn.assigns.scope, params, Clock.now()) do
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, body)
    end
  end
end
