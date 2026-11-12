defmodule ApiTeam.LeadNoteController do
  @moduledoc """
  A lead's notes (AQ-04B §8.1): `GET /leads/:id/notes`, `POST
  /leads/:id/notes {body_md}`, `PATCH /lead-notes/:id {body_md}`, `DELETE
  /lead-notes/:id`. `Core.Leads.Notes` decides; `ApiShared.LeadsJSON.note/1`
  lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads.Notes

  action_fallback ApiShared.FallbackController

  def index(conn, %{"id" => id}) do
    with {:ok, notes} <- Notes.list(conn.assigns.scope, id),
         do: json(conn, Enum.map(notes, &LeadsJSON.note/1))
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, note} <- Notes.add(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      conn |> put_status(:created) |> json(LeadsJSON.note(note))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, note} <- Notes.edit(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, LeadsJSON.note(note))
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Notes.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
