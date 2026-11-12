defmodule ApiExt.NotificationController do
  @moduledoc """
  `GET /notifications/pop-ups` (AQ-08 §7.5, §11.4): the extension's minute
  poll claims the person's due pop-ups, so a second poll, or a second
  device, gets nothing. On a device token only (`ApiShared.Plugs.TokenApp`):
  a console or portal token is the pipeline's `401`.
  `Core.Notifications.PopUps` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.PopUps

  action_fallback ApiShared.FallbackController

  def pop_ups(conn, _params) do
    with {:ok, answer} <- PopUps.claim(conn.assigns.scope, Clock.now()), do: json(conn, answer)
  end
end
