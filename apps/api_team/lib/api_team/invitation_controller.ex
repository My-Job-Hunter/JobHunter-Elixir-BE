defmodule ApiTeam.InvitationController do
  @moduledoc "Invitations, from the staff side (AQ-01 §6.2)."

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Organisation.Invitations

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, invitations} <- Invitations.list(conn.assigns.scope, params) do
      render(conn, :index, invitations: invitations, now: Clock.now())
    end
  end

  def create(conn, params) do
    with {:ok, invitation, status} <- Invitations.issue(conn.assigns.scope, params, Clock.now()) do
      conn
      |> put_status(if(status == :issued, do: :created, else: :ok))
      |> render(:show, invitation: invitation, now: Clock.now())
    end
  end

  def revoke(conn, %{"id" => id}) do
    with {:ok, invitation} <- Invitations.revoke(conn.assigns.scope, id, Clock.now()) do
      render(conn, :show, invitation: invitation, now: Clock.now())
    end
  end

  def resend(conn, %{"id" => id}) do
    with {:ok, invitation} <- Invitations.resend(conn.assigns.scope, id, Clock.now()) do
      render(conn, :show, invitation: invitation, now: Clock.now())
    end
  end
end
