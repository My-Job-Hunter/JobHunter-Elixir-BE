defmodule ApiTeam.ExtensionController do
  @moduledoc """
  Settings › Extension (AQ-05 §11.2), the system admin's (404 for anyone
  else): `GET /extension/health` (`health`: per site its live config, the
  last 7 days' misses and its last capture; every live device) and
  `GET /extension/configs?site` (`[{site, version, sha256, published_at}]`,
  newest first).
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Clock
  alias Core.Extension.{Configs, Health}

  action_fallback ApiShared.FallbackController

  def health(conn, _params) do
    with {:ok, health} <- Health.page(conn.assigns.scope, Clock.now()),
         do: json(conn, ExtensionJSON.health(health))
  end

  def configs(conn, params) do
    with {:ok, configs} <- Configs.list(conn.assigns.scope, params),
         do: json(conn, ExtensionJSON.configs(configs))
  end
end
