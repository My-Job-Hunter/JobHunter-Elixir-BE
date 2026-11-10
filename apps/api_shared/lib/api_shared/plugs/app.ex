defmodule ApiShared.Plugs.App do
  @moduledoc """
  Names the app a request reached, in `conn.assigns.app`: `"team"`,
  `"client"` or `"ext"`.

  Each app's router puts it in its pipeline, so a shared controller can tell
  the team console's request from the portal's or the extension's without
  reading the path.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(app) when is_binary(app), do: app

  @impl Plug
  def call(conn, app), do: assign(conn, :app, app)
end
