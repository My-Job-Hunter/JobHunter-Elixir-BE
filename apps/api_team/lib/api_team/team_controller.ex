defmodule ApiTeam.TeamController do
  @moduledoc "Teams, their settings and their members (JH-01 §6.2)."

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Organisation.Teams

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    with {:ok, teams} <- Teams.list(conn.assigns.scope), do: render(conn, :index, teams: teams)
  end

  def create(conn, params) do
    with {:ok, team} <- Teams.create(conn.assigns.scope, params) do
      conn
      |> put_status(:created)
      |> render(:show, team: team)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, team} <- Teams.get(conn.assigns.scope, id), do: render(conn, :show, team: team)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, team} <- Teams.update(conn.assigns.scope, id, params),
         do: render(conn, :show, team: team)
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, team} <- Teams.archive(conn.assigns.scope, id, Clock.now()),
         do: render(conn, :show, team: team)
  end

  def settings(conn, %{"id" => id}) do
    with {:ok, settings} <- Teams.get_settings(conn.assigns.scope, id) do
      render(conn, :settings, settings: settings)
    end
  end

  def put_settings(conn, %{"id" => id} = params) do
    with {:ok, settings} <- Teams.put_settings(conn.assigns.scope, id, params) do
      render(conn, :settings, settings: settings)
    end
  end

  def members(conn, %{"id" => id}) do
    with {:ok, members} <- Teams.list_members(conn.assigns.scope, id) do
      render(conn, :members, members: members)
    end
  end

  def change_role(conn, %{"id" => id, "user_id" => user_id, "role" => role}) do
    with {:ok, member} <- Teams.change_role(conn.assigns.scope, id, user_id, role) do
      render(conn, :member, member: member)
    end
  end

  def change_role(_conn, _params), do: {:error, {:missing, :role}}

  def remove_member(conn, %{"id" => id, "user_id" => user_id}) do
    with :ok <- Teams.remove_member(conn.assigns.scope, id, user_id, Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end
end
