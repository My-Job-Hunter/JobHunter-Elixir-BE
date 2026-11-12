defmodule ApiTeam.OrgController do
  @moduledoc """
  *Settings › System* (AQ-04A §8.5): the organisation, its timings and its
  audit log, the system admin's alone. No admins list: the one system admin
  is handed on with `mix aq.admin`.
  """

  use Phoenix.Controller, formats: [:json]

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

  def audit(conn, params) do
    with {:ok, events, next_cursor} <- Organisation.list_audit(conn.assigns.scope, params) do
      render(conn, :audit, events: events, next_cursor: next_cursor)
    end
  end
end
