defmodule ApiShared.Plugs.AuthPipeline do
  @moduledoc """
  The authenticated pipeline: verify the bearer token, refuse without one,
  load the user.

  `EnsureAuthenticated` runs before `LoadResource`, so a request with no valid
  token is refused before anything is looked up. A refusal is always `401`
  with the code `unauthenticated` (`Core.Auth.ErrorHandler`).

  **Wired, and unused by any route in P0**: there are no users to load. P1's
  routes pipe through it, with `ApiShared.Plugs.Scope` after it.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    module: Core.Auth.Guardian,
    error_handler: Core.Auth.ErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  # AQ-05 §7: a device's token on `/ext` only, and no other token there.
  plug ApiShared.Plugs.TokenApp
  plug Guardian.Plug.LoadResource
  plug :assign_current_user

  # Guardian keeps the resource in its own private storage; the rest of the
  # app should not need to know that.
  defp assign_current_user(conn, _opts) do
    Plug.Conn.assign(conn, :current_user, Guardian.Plug.current_resource(conn))
  end
end
