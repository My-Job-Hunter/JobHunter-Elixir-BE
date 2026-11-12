defmodule ApiExt.Plugs.Device do
  @moduledoc """
  The device behind an `/ext/v1` token (AQ-05 §4, §7): the live device the
  token's `sid` names, of a live staff account, in `conn.assigns.device`;
  `401 unauthenticated` otherwise — a disconnected device's token stops at
  its next request even before it expires. The device's `last_seen_at`
  moves, at most once a minute.

  Runs after `:aq_authenticated`, so the token, the user and the scope
  (`via: :extension`) are there.
  """

  import Plug.Conn

  alias Core.Auth.ErrorHandler
  alias Core.Clock
  alias Core.Extension

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{scope: scope}} = conn, _opts) do
    sid = (Guardian.Plug.current_claims(conn) || %{})["sid"]

    case Extension.live_device(scope, sid) do
      {:ok, device} ->
        :ok = Extension.seen(scope, device, Clock.now())
        assign(conn, :device, device)

      {:error, :unauthenticated} ->
        refuse(conn)
    end
  end

  def call(conn, _opts), do: refuse(conn)

  defp refuse(conn),
    do: conn |> ErrorHandler.auth_error({:unauthenticated, :no_device}, []) |> halt()
end
