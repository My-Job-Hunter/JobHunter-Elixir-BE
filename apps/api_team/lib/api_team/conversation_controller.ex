defmodule ApiTeam.ConversationController do
  @moduledoc """
  Conversations and triage in the console (AQ-06 §7, §11.1): a lead's
  conversations (each with its tree), one conversation, *Log message*
  (`POST /messages`, 201), its edit and delete (hand-typed only),
  `POST /eml` (201; 200 when every message was already here), *Classify*,
  and the team's triage with *Link to lead*, *Ignore* / *Undo*, *Create
  job and lead* (201) and *Mark as recruiter*. `Core.Conversations.*`
  decides; `ApiShared.ConversationsJSON` lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ConversationsJSON, as: JSON
  alias Core.Clock
  alias Core.Conversations
  alias Core.Conversations.{Classify, Inbox, Messages, Triage}

  action_fallback ApiShared.FallbackController

  def for_lead(conn, %{"id" => id}) do
    with {:ok, list} <- Conversations.for_lead(conn.assigns.scope, id),
         do: json(conn, Enum.map(list, &JSON.conversation/1))
  end

  def show(conn, %{"id" => id}), do: conversation(conn, Conversations.get(conn.assigns.scope, id))

  # ── Messages ────────────────────────────────────────────────────────────────

  def create_message(conn, params) do
    with {:ok, c} <- Messages.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(JSON.conversation(c))
    end
  end

  def update_message(conn, %{"id" => id} = params),
    do:
      conversation(
        conn,
        Messages.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now())
      )

  def delete_message(conn, %{"id" => id}) do
    with :ok <- Messages.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  def classify(conn, %{"id" => id} = params) do
    with {:ok, answer} <-
           Classify.run(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, JSON.classified(answer))
  end

  def eml(conn, params) do
    case Inbox.eml(conn.assigns.scope, params, Clock.now()) do
      {:ok, {:created, answer}} -> conn |> put_status(:created) |> json(JSON.eml(answer))
      {:ok, {:already, answer}} -> json(conn, JSON.eml(answer))
      error -> error
    end
  end

  # ── Triage ──────────────────────────────────────────────────────────────────

  def triage(conn, params) do
    with {:ok, page} <- Triage.list(conn.assigns.scope, params), do: json(conn, JSON.triage(page))
  end

  def link(conn, %{"id" => id} = params),
    do: conversation(conn, Triage.link(conn.assigns.scope, id, params, Clock.now()))

  def ignore(conn, %{"id" => id}),
    do: conversation(conn, Triage.ignore(conn.assigns.scope, id, Clock.now()))

  def unignore(conn, %{"id" => id}),
    do: conversation(conn, Triage.unignore(conn.assigns.scope, id, Clock.now()))

  def create_lead(conn, %{"id" => id} = params) do
    with {:ok, answer} <-
           Triage.create_lead(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      conn |> put_status(:created) |> json(JSON.created_lead(answer))
    end
  end

  def recruiter(conn, %{"id" => id} = params) do
    with {:ok, answer} <-
           Triage.recruiter(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, JSON.recruited(answer))
  end

  defp conversation(conn, {:ok, c}), do: json(conn, JSON.conversation(c))
  defp conversation(_conn, error), do: error
end
