defmodule ApiShared.NotificationSettingsController do
  @moduledoc """
  Notifications › Settings (AQ-08 §8, §11.4), served by both apps: the
  switches per group and channel with quiet hours, the digest, the zone and
  what the person has. `Core.Notifications.Settings` decides; quiet hours
  and the digest are still saved through `PUT /me/settings`.

  `has.push` is about this app's browsers: the surface's (`team` on
  `/team/v1`, `client` on `/client/v1`), never the body's.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.Settings

  action_fallback ApiShared.FallbackController

  @doc "`GET /notifications/settings`: **settings**."
  def show(conn, _params) do
    with {:ok, settings} <- Settings.get(conn.assigns.scope, app(conn)), do: json(conn, settings)
  end

  @doc "`PUT /notifications/settings/groups/:key` `{push?, email?, extension?, digest?}`: **settings**."
  def put_group(conn, %{"key" => key} = params) do
    switches = Map.take(params, ~w(push email extension digest))

    with {:ok, settings} <-
           Settings.put_group(conn.assigns.scope, key, switches, app(conn), Clock.now()),
         do: json(conn, settings)
  end

  @doc "The app a request reached, as push names it: the portal's `client`, else `team`."
  @spec app(Plug.Conn.t()) :: :team | :client
  def app(%Plug.Conn{assigns: %{app: "client"}}), do: :client
  def app(_conn), do: :team
end
