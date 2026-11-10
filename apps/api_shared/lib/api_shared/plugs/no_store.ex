defmodule ApiShared.Plugs.NoStore do
  @moduledoc """
  `Cache-Control: no-store` on every shared response: tokens and personal data
  must never sit in a browser's or a proxy's cache.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")
end
