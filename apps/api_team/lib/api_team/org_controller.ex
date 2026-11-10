defmodule ApiTeam.OrgController do
  @moduledoc "The organisation, its timings, its admins and its audit log (JH-01 §6.2)."

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Organisation

  action_fallback ApiShared.FallbackController

  def show(conn, _params) do
    with {:ok, org} <- Organisation.get(conn.assigns.scope) do
      render(conn, :show, organisation: org.organisation, settings: org.settings)
    end
  end

  def update_settings(conn, params) do
    with {:ok, org} <- Organisation.update_settings(conn.assigns.scope, params) do
      render(conn, :show, organisation: org.organisation, settings: org.settings)
    end
  end

  def admins(conn, _params) do
    with {:ok, admins} <- Organisation.list_admins(conn.assigns.scope) do
      render(conn, :admins, admins: admins)
    end
  end

  def grant_admin(conn, %{"user_id" => user_id}) do
    with {:ok, admin} <- Organisation.grant_admin(conn.assigns.scope, user_id, Clock.now()) do
      conn
      |> put_status(:created)
      |> render(:admin, admin: admin)
    end
  end

  def grant_admin(_conn, _params), do: {:error, {:missing, :user_id}}

  def revoke_admin(conn, %{"user_id" => user_id}) do
    with :ok <- Organisation.revoke_admin(conn.assigns.scope, user_id, Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end

  def audit(conn, params) do
    with {:ok, events, next_cursor} <- Organisation.list_audit(conn.assigns.scope, params) do
      render(conn, :audit, events: events, next_cursor: next_cursor)
    end
  end
end
