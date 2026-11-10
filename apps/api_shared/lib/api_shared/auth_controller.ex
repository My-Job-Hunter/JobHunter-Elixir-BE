defmodule ApiShared.AuthController do
  @moduledoc """
  Sign-in, the tokens, the invitation and the reset (JH-01 §6.1), for every
  app at its own prefix. **Thin on purpose**: every rule is `Core.Accounts`,
  `Core.Accounts.Recovery` or `Core.Organisation.Invitations`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Accounts
  alias Core.Accounts.Recovery
  alias Core.Auth.Guardian
  alias Core.Clock
  alias Core.Organisation.Invitations
  alias Core.Plugs.RateLimit

  action_fallback ApiShared.FallbackController

  @doc "`POST /auth/login {email, password}`: the pair and the user; one answer for a wrong email or password."
  def login(conn, params) do
    with {:ok, user} <- Accounts.sign_in(params["email"], params["password"], Clock.now()),
         {:ok, tokens} <- Guardian.tokens_for(user, session(conn)) do
      render(conn, :session, tokens: tokens, user: user)
    end
  end

  @doc "`POST /auth/google {id_token}`: the pair for an account that already has the address (QP1-5)."
  def google(conn, params) do
    with {:ok, user} <- Accounts.google_sign_in(params["id_token"], Clock.now()),
         {:ok, tokens} <- Guardian.tokens_for(user, session(conn)) do
      render(conn, :session, tokens: tokens, user: user)
    end
  end

  @doc "`POST /auth/refresh {refresh_token}`: a new pair; the old refresh revoked."
  def refresh(conn, %{"refresh_token" => token}) when is_binary(token) do
    with {:ok, tokens} <- Guardian.exchange_refresh_token(token) do
      render(conn, :tokens, tokens: tokens)
    end
  end

  def refresh(_conn, _params), do: {:error, :invalid_refresh_token}

  @doc "`POST /auth/logout`: this session's tokens, by `sid`. 204."
  def logout(conn, _params) do
    :ok = Accounts.logout(conn.assigns.scope, sid(conn))
    send_resp(conn, :no_content, "")
  end

  @doc "`POST /auth/logout-all`: every token of the user. 204."
  def logout_all(conn, _params) do
    :ok = Accounts.logout_all(conn.assigns.scope)
    send_resp(conn, :no_content, "")
  end

  @doc "`GET /auth/invitations/:code`: what this invitation is, before accepting."
  def invitation(conn, %{"code" => code}) do
    with {:ok, preview} <- Invitations.preview(code, Clock.now()) do
      render(conn, :invitation, invitation: preview)
    end
  end

  @doc """
  `POST /auth/invitations/:code/accept {name?, password?, id_token?}`, or
  signed in: the account made or the role added, and the pair plus `landing`.
  """
  def accept_invitation(conn, %{"code" => code} = params) do
    with {:ok, %{user: user, landing: landing}} <-
           Invitations.accept(code, Map.take(params, ~w(name password id_token)),
             current_user: conn.assigns[:current_user],
             now: Clock.now()
           ),
         {:ok, tokens} <- Guardian.tokens_for(user, session(conn)) do
      conn
      |> put_status(:created)
      |> render(:session, tokens: tokens, user: user, landing: landing)
    end
  end

  @doc "`POST /auth/password/forgot {email}`: 202 whatever happened."
  def forgot_password(conn, params) do
    :ok =
      Recovery.request_password_reset(params["email"],
        requested_ip: RateLimit.client_ip(conn),
        now: Clock.now()
      )

    send_resp(conn, :accepted, "")
  end

  @doc "`POST /auth/password/reset {token, password}`: 204; a dead link is 410, a weak password 422."
  def reset_password(conn, params) do
    with {:ok, _user} <- Recovery.reset_password(params["token"], params["password"], Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end

  # The device that signed in, for `/me/sessions`: the app, the agent, the address.
  defp session(conn) do
    agent =
      conn |> get_req_header("user-agent") |> List.first() |> to_string() |> String.slice(0, 200)

    Accounts.session_claims(%{
      "app" => conn.assigns[:app] || "team",
      "agent" => agent,
      "ip" => RateLimit.client_ip(conn)
    })
  end

  defp sid(conn) do
    case Guardian.Plug.current_claims(conn) do
      %{"sid" => sid} -> sid
      _none -> nil
    end
  end
end
