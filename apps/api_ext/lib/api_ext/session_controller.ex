defmodule ApiExt.SessionController do
  @moduledoc """
  Connecting and disconnecting (AQ-05 §7, §11.1): `POST /session {code,
  extension_version}` exchanges the console's one-time code for a device
  and its token pair (201; a dead or used code is P1's 410
  `token_invalid`); `DELETE /session` disconnects this device (204).
  `Core.Extension` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Accounts
  alias Core.Clock
  alias Core.Extension
  alias Core.Plugs.RateLimit

  action_fallback ApiShared.FallbackController

  def create(conn, params) do
    client = %{
      agent: conn |> get_req_header("user-agent") |> List.first(),
      ip: RateLimit.client_ip(conn),
      request_id: conn |> get_resp_header("x-request-id") |> List.first()
    }

    with {:ok, %{device: device, tokens: tokens, scope: scope}} <-
           Extension.connect(params["code"], params, client, Clock.now()) do
      conn
      |> put_status(:created)
      |> json(ExtensionJSON.session(%{tokens: tokens, device: device, me: Accounts.me(scope)}))
    end
  end

  def delete(conn, _params) do
    with {:ok, _device} <-
           Extension.disconnect(conn.assigns.scope, conn.assigns.device.id, Clock.now()) do
      send_resp(conn, :no_content, "")
    end
  end
end
