defmodule ApiTeam.MeetingController do
  @moduledoc """
  Meetings in the console (AQ-06 §8, §11.1): the Meetings page
  (`GET /meetings?team_id&from&to`), a lead's meetings, *Schedule meeting*
  (201, with its `clash`), a meeting, its edit, the verbs (reschedule,
  cancel, done, no-show: 200), the clash check (with the stage a kind
  offers) and the ICS file (`GET /meetings/:id/ics`, `text/calendar`).
  `Core.Meetings` decides; `ApiShared.ConversationsJSON` lists the fields.
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

  def for_lead(conn, %{"id" => id}) do
    with {:ok, list} <- Meetings.for_lead(conn.assigns.scope, id, Clock.now()),
         do: json(conn, Enum.map(list, &JSON.meeting/1))
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, m} <-
           Meetings.schedule(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      conn |> put_status(:created) |> json(JSON.meeting(m))
    end
  end

  def show(conn, %{"id" => id}), do: meeting(conn, Meetings.get(conn.assigns.scope, id))

  def update(conn, %{"id" => id} = params),
    do:
      meeting(
        conn,
        Meetings.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now())
      )

  def reschedule(conn, %{"id" => id} = params),
    do: meeting(conn, Meetings.reschedule(conn.assigns.scope, id, params, Clock.now()))

  def cancel(conn, %{"id" => id} = params),
    do: meeting(conn, Meetings.cancel(conn.assigns.scope, id, params, Clock.now()))

  def done(conn, %{"id" => id} = params),
    do: meeting(conn, Meetings.done(conn.assigns.scope, id, params, Clock.now()))

  def no_show(conn, %{"id" => id} = params),
    do: meeting(conn, Meetings.no_show(conn.assigns.scope, id, params, Clock.now()))

  def clash(conn, params) do
    with {:ok, clash} <- Meetings.clash(conn.assigns.scope, params),
         do: json(conn, JSON.clash(clash))
  end

  def ics(conn, %{"id" => id}), do: ics_file(conn, Meetings.ics(conn.assigns.scope, id))

  @doc false
  def ics_file(conn, {:ok, filename, body}) do
    conn
    |> put_resp_content_type("text/calendar", "utf-8")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, body)
  end

  def ics_file(_conn, error), do: error

  defp meeting(conn, {:ok, m}), do: json(conn, JSON.meeting(m))
  defp meeting(_conn, error), do: error
end
