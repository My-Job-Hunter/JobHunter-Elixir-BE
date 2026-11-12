defmodule ApiTeam.PeopleController do
  @moduledoc "The staff list, and suspending an account (AQ-01 §6.2, QP1-10)."

  use Phoenix.Controller, formats: [:json]

  alias Core.Accounts
  alias Core.Clock
  alias Core.Organisation

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, people} <- Organisation.list_people(conn.assigns.scope, params) do
      json(conn, people)
    end
  end

  def suspend(conn, %{"user_id" => user_id}) do
    with {:ok, _user} <- Accounts.suspend(conn.assigns.scope, user_id, Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end

  def unsuspend(conn, %{"user_id" => user_id}) do
    with {:ok, _user} <- Accounts.unsuspend(conn.assigns.scope, user_id) do
      send_resp(conn, :no_content, "")
    end
  end
end
