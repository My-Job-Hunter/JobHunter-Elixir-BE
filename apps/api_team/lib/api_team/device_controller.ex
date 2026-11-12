defmodule ApiTeam.DeviceController do
  @moduledoc """
  The extension's devices in the console (AQ-05 §7, §11.2):
  `POST /devices/connect-codes {}` → 201 `{code, expires_at}` for
  `/extension/connect`; `GET /devices` (the caller's live devices) and
  `?all=true` (every one, the system admin's); `DELETE /devices/:id` (204;
  the owner or the system admin). `Core.Extension` decides; a device's
  `current` is false here.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Clock
  alias Core.Extension
  alias Core.Plugs.RateLimit

  action_fallback ApiShared.FallbackController

  def connect_code(conn, _params) do
    with {:ok, code} <-
           Extension.connect_code(conn.assigns.scope, Clock.now(), ip: RateLimit.client_ip(conn)) do
      conn |> put_status(:created) |> json(%{code: code.code, expires_at: code.expires_at})
    end
  end

  def index(conn, params) do
    with {:ok, devices} <- Extension.list(conn.assigns.scope, params),
         do: json(conn, Enum.map(devices, &ExtensionJSON.device/1))
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _device} <- Extension.disconnect(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
