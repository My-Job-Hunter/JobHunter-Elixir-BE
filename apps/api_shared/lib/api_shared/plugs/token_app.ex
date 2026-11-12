defmodule ApiShared.Plugs.TokenApp do
  @moduledoc """
  Keeps each token in its own app (AQ-05 §7, QP5-5): **a device token works
  only on `/ext/v1`, and a console or portal token never works there** —
  told apart by the token's `dev.app` claim
  (`Core.Auth.Guardian.extension_token?/1`) against the app the request
  reached (`conn.assigns.app`, `ApiShared.Plugs.App`). The wrong one is the
  pipeline's own `401 unauthenticated`, as a forged token is.

  Runs inside `ApiShared.Plugs.AuthPipeline` and `MaybeAuthPipeline`, after
  the header is verified; a request with no token passes untouched.
  """

  import Plug.Conn

  alias Core.Auth.ErrorHandler
  alias Core.Auth.Guardian

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Guardian.Plug.current_claims(conn) do
      nil ->
        conn

      claims ->
        if Guardian.extension_token?(claims) == (conn.assigns[:app] == "ext"),
          do: conn,
          else: conn |> ErrorHandler.auth_error({:invalid_token, :wrong_app}, []) |> halt()
    end
  end
end
