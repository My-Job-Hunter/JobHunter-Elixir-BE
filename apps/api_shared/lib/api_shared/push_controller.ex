defmodule ApiShared.PushController do
  @moduledoc """
  Push on this browser (AQ-08 §7.6, §11.4; mCart's), served by both apps:
  the server's public key and the person's browsers, a browser turned on or
  taken off, and *Send a test*. **`app` is the surface's** (`/team/v1` →
  `team`, `/client/v1` → `client`), never the body's. `Core.Notifications.Push`
  decides; `notifire`'s sweep sends.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.NotificationSettingsController, as: Settings
  alias Core.Clock
  alias Core.Notifications.Push

  action_fallback ApiShared.FallbackController

  @doc "`GET /me/push`: **push page**."
  def show(conn, _params) do
    with {:ok, page} <- Push.page(conn.assigns.scope), do: json(conn, page)
  end

  @doc "`POST /me/push` `{endpoint, keys: {p256dh, auth}, user_agent?}`: 201 **push page**."
  def create(conn, params) do
    params =
      Map.put_new_lazy(params, "user_agent", fn ->
        conn |> get_req_header("user-agent") |> List.first()
      end)

    with {:ok, page} <-
           Push.subscribe(conn.assigns.scope, Settings.app(conn), params, Clock.now()) do
      conn |> put_status(:created) |> json(page)
    end
  end

  @doc "`DELETE /me/push` `{endpoint}`: **push page**."
  def delete(conn, params) do
    with {:ok, page} <- Push.remove(conn.assigns.scope, params), do: json(conn, page)
  end

  @doc "`POST /me/push/test`: 202 `{}`, the test raised through the pipeline."
  def test(conn, _params) do
    with :ok <- Push.test(conn.assigns.scope, Clock.now()) do
      conn |> put_status(:accepted) |> json(%{})
    end
  end
end
