defmodule Core.Auth.ErrorHandler do
  @moduledoc """
  What the pipeline returns when a token is missing, expired or forged.

  Always `401` with a stable `code`, never a description of *why* — "expired"
  versus "forged" is information an attacker can use and a client cannot act
  on differently.
  """

  import Plug.Conn

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {_type, _reason}, _opts) do
    body =
      Jason.encode!(%{
        error: %{
          code: "unauthenticated",
          message: "You need to sign in to do that.",
          details: %{}
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
  end
end
