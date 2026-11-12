defmodule ApiClient.MeetingController do
  @moduledoc """
  The customer's meetings in the portal (AQ-06 §8.4, §11.2): `GET
  /meetings` (their own, upcoming first; `from`/`to` for a window) and
  `GET /meetings/:id/ics` (*Add to calendar*). The scope is pinned to the
  customer; `Core.Meetings` cuts what they read.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ConversationsJSON, as: JSON
  alias Core.Clock
  alias Core.Meetings

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Meetings.list(conn.assigns.scope, params, Clock.now()),
         do: json(conn, JSON.meetings(page))
  end

  def ics(conn, %{"id" => id}) do
    with {:ok, filename, body} <- Meetings.ics(conn.assigns.scope, id) do
      conn
      |> put_resp_content_type("text/calendar", "utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, body)
    end
  end
end
