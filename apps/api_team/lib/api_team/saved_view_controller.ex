defmodule ApiTeam.SavedViewController do
  @moduledoc """
  A person's saved views (AQ-04B §8.1, §9): `GET /saved-views?screen`,
  `POST /saved-views {screen, name, query, columns?}`, `PATCH
  /saved-views/:id {name?, query?, columns?, position?}`, `DELETE
  /saved-views/:id` — their owner's alone. `Core.SavedViews` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.SavedViews

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, views} <- SavedViews.list(conn.assigns.scope, params),
         do: json(conn, Enum.map(views, &LeadsJSON.saved_view/1))
  end

  def create(conn, params) do
    with {:ok, view} <- SavedViews.create(conn.assigns.scope, params) do
      conn |> put_status(:created) |> json(LeadsJSON.saved_view(view))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, view} <- SavedViews.update(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, LeadsJSON.saved_view(view))
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- SavedViews.delete(conn.assigns.scope, id), do: send_resp(conn, :no_content, "")
  end
end
