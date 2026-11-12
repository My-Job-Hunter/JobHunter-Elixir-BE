defmodule ApiTeam.ContactController do
  @moduledoc """
  Contacts in the console (AQ-06 §6, §11.1): the list, the match check,
  *New contact* (201; 409 `contact_exists` for a handle another contact
  holds; 200 when `use_possible` used the possible match), a contact, its
  edit and handles, *Merge*, its conversations and meetings, and a lead's
  contacts (`POST /leads/:id/contacts` answers the lead's `recruiters`).
  `Core.Contacts` decides; `ApiShared.ConversationsJSON` lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ConversationsJSON, as: JSON
  alias Core.Clock
  alias Core.Contacts
  alias Core.Contacts.LeadLinks

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Contacts.list(conn.assigns.scope, params),
         do: json(conn, JSON.contacts(page))
  end

  def match(conn, params) do
    with {:ok, match} <- Contacts.match(conn.assigns.scope, params),
         do: json(conn, JSON.match(match))
  end

  def create(conn, params) do
    case Contacts.create(conn.assigns.scope, params, Clock.now()) do
      {:ok, {:created, contact}} -> conn |> put_status(:created) |> json(JSON.contact(contact))
      {:ok, {:used, contact}} -> json(conn, JSON.contact(contact))
      error -> error
    end
  end

  def show(conn, %{"id" => id}), do: contact(conn, Contacts.get(conn.assigns.scope, id))

  def update(conn, %{"id" => id} = params),
    do:
      contact(
        conn,
        Contacts.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now())
      )

  def add_handle(conn, %{"id" => id} = params) do
    with {:ok, contact} <-
           Contacts.add_handle(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      conn |> put_status(:created) |> json(JSON.contact(contact))
    end
  end

  def remove_handle(conn, %{"id" => id}) do
    with :ok <- Contacts.remove_handle(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  def merge(conn, %{"id" => id} = params),
    do:
      contact(conn, Contacts.merge(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()))

  def conversations(conn, %{"id" => id}) do
    with {:ok, list} <- Core.Conversations.for_contact(conn.assigns.scope, id),
         do: json(conn, Enum.map(list, &JSON.conversation/1))
  end

  def meetings(conn, %{"id" => id}) do
    with {:ok, list} <- Core.Meetings.for_contact(conn.assigns.scope, id),
         do: json(conn, Enum.map(list, &JSON.meeting/1))
  end

  # ── A lead's contacts ───────────────────────────────────────────────────────

  def link_lead(conn, %{"id" => id} = params) do
    with {:ok, recruiters} <-
           LeadLinks.link(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      json(conn, Enum.map(recruiters, &JSON.recruiter/1))
    end
  end

  def unlink_lead(conn, %{"id" => id, "contact_id" => contact_id}) do
    with :ok <- LeadLinks.unlink(conn.assigns.scope, id, contact_id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  defp contact(conn, {:ok, contact}), do: json(conn, JSON.contact(contact))
  defp contact(_conn, error), do: error
end
