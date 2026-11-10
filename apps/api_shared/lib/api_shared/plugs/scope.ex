defmodule ApiShared.Plugs.Scope do
  @moduledoc """
  Turns an authenticated request into a `%Data.Scope{}`, in
  `conn.assigns.scope`, **once per request** (JH-01 §5.1).

  Runs after `ApiShared.Plugs.AuthPipeline`, so `conn.assigns.current_user`
  is already there. `Core.Access.Grants.scope_for/2` resolves the
  organisation and the roles (`admin?`, the team roles; `customer_id` from
  P1.2). Every controller hands this scope to the context it calls; no
  controller builds one.

  The portal's `ApiClient.Plugs.CustomerScope` (P1.3) runs after this and
  pins the scope to the customer, refusing a staff account with 404.
  """

  import Plug.Conn

  alias Core.Access.Grants

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) when not is_nil(user) do
    request_id = conn |> get_resp_header("x-request-id") |> List.first()
    assign(conn, :scope, Grants.scope_for(user, via: :web, request_id: request_id))
  end

  def call(conn, _opts), do: conn
end
