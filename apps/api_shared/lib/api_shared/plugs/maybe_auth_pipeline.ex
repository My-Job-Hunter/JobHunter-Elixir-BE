defmodule ApiShared.Plugs.MaybeAuthPipeline do
  @moduledoc """
  A bearer token if there is one, nobody otherwise. For the one route that
  serves both: `POST /auth/invitations/:code/accept`, which a signed-in
  person accepts with one press and a new person accepts with a name and a
  password (JH-01 §3).

  A token that is present but bad is still refused (`401`): a stale token is
  a question to answer, not something to quietly ignore.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    module: Core.Auth.Guardian,
    error_handler: Core.Auth.ErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.LoadResource, allow_blank: true
  plug :assign_current_user

  defp assign_current_user(conn, _opts) do
    Plug.Conn.assign(conn, :current_user, Guardian.Plug.current_resource(conn))
  end
end
