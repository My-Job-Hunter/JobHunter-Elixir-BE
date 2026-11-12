defmodule ApiTeam.LabelController do
  @moduledoc """
  A team's labels (AQ-04B §8.1, §9): `GET /labels?team_id`, `POST /labels
  {team_id, name}`, `PATCH /labels/:id {name}`, `DELETE /labels/:id`.
  `Core.Leads.Labels` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads.Labels

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, labels} <- Labels.list(conn.assigns.scope, params),
         do: json(conn, Enum.map(labels, &LeadsJSON.label/1))
  end

  def create(conn, params) do
    with {:ok, label} <- Labels.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(LeadsJSON.label(label))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, label} <- Labels.rename(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, LeadsJSON.label(label))
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Labels.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
