defmodule ApiTeam.RetentionController do
  @moduledoc """
  Settings › Retention (AQ-04B §7.4, §8.1): `GET /retention/preview?team_id?`
  — what archives and purges in the next 14 days. `Core.Retention` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Retention

  action_fallback ApiShared.FallbackController

  def preview(conn, params) do
    with {:ok, preview} <- Retention.preview(conn.assigns.scope, params, Clock.now()),
         do: json(conn, LeadsJSON.preview(preview))
  end
end
