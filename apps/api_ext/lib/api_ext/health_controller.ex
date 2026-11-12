defmodule ApiExt.HealthController do
  @moduledoc """
  `POST /health {extension_version, misses: [{site, page_kind, selector_key,
  config_version, count}]}` (AQ-05 §5.2, §11.4): 204. `Core.Extension.Health`
  decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Extension.Health

  action_fallback ApiShared.FallbackController

  def create(conn, params) do
    with :ok <- Health.report(conn.assigns.scope, params, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
