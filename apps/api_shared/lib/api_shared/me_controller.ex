defmodule ApiShared.MeController do
  @moduledoc """
  The account page (AQ-01 §6.1): who I am, my settings, my password, my
  email, my sessions. Every action hands `conn.assigns.scope` to
  `Core.Accounts` and renders what comes back.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Accounts
  alias Core.Accounts.Recovery
  alias Core.Clock

  action_fallback ApiShared.FallbackController

  @doc "`GET /me`."
  def show(conn, _params), do: render(conn, :me, me: Accounts.me(conn.assigns.scope))

  @doc "`PATCH /me`: name, photo, timezone, locale."
  def update(conn, params) do
    with {:ok, me} <- Accounts.update_me(conn.assigns.scope, params) do
      render(conn, :me, me: me)
    end
  end

  @doc "`PUT /me/settings`: theme, quiet hours, digest."
  def put_settings(conn, params) do
    with {:ok, settings} <- Accounts.put_settings(conn.assigns.scope, params) do
      render(conn, :settings, settings: settings)
    end
  end

  @doc "`POST /me/password {current, new}`. 204."
  def change_password(conn, params) do
    with :ok <- Accounts.change_password(conn.assigns.scope, params["current"], params["new"]) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "`POST /me/email {new_email}`: a link to the new address. 202."
  def request_email_change(conn, params) do
    with :ok <-
           Recovery.request_email_change(conn.assigns.scope, params["new_email"], Clock.now()) do
      send_resp(conn, :accepted, "")
    end
  end

  @doc "`POST /me/email/confirm {token}`. 204."
  def confirm_email_change(conn, params) do
    with {:ok, _user} <-
           Recovery.confirm_email_change(conn.assigns.scope, params["token"], Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "`GET /me/sessions`: by `sid`, the current one marked."
  def sessions(conn, _params) do
    sessions = Accounts.list_sessions(conn.assigns.scope, current_sid(conn), Clock.now())
    render(conn, :sessions, sessions: sessions)
  end

  @doc "`DELETE /me/sessions/:sid`. 204."
  def revoke_session(conn, %{"sid" => sid}) do
    with :ok <- Accounts.revoke_session(conn.assigns.scope, sid) do
      send_resp(conn, :no_content, "")
    end
  end

  defp current_sid(conn) do
    case Guardian.Plug.current_claims(conn) do
      %{"sid" => sid} -> sid
      _none -> nil
    end
  end
end
