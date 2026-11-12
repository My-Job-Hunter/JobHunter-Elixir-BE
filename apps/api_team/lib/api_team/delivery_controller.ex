defmodule ApiTeam.DeliveryController do
  @moduledoc """
  `GET /deliveries/health` (AQ-08 §9, §11.4): Settings › System's delivery
  health, the system admin's alone. `Core.Notifications.Health` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications.Health

  action_fallback ApiShared.FallbackController

  def health(conn, _params) do
    with {:ok, health} <- Health.get(conn.assigns.scope, Clock.now()), do: json(conn, health)
  end
end
