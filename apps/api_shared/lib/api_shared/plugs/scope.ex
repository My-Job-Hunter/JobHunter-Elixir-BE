defmodule ApiShared.Plugs.Scope do
  @moduledoc """
  Turns an authenticated request into a `%Data.Scope{}`, in
  `conn.assigns.scope`, **once per request** (AQ-01 §5.1).

  Runs after `ApiShared.Plugs.AuthPipeline`, so `conn.assigns.current_user`
  is already there. `Core.Access.Grants.scope_for/2` resolves the
  organisation and the roles (`admin?`, the team roles; `customer_id` from
  P1.2). Every controller hands this scope to the context it calls; no
  controller builds one.

  `via` is `:extension` on `/ext` (AQ-05 §11.4), `:web` everywhere else.

  The portal's `ApiClient.Plugs.CustomerScope` (P1.3) runs after this and
  pins the scope to the customer, refusing a staff account with 404.
  """

  import Plug.Conn

  alias Core.Access.Grants

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) when not is_nil(user) do
    request_id = conn |> get_resp_header("x-request-id") |> List.first()
    assign(conn, :scope, Grants.scope_for(user, via: via(conn), request_id: request_id))
  end

  def call(conn, _opts), do: conn

  # AQ-05 §11.4: every `/ext/v1` request acts `via: :extension`.
  defp via(%Plug.Conn{assigns: %{app: "ext"}}), do: :extension
  defp via(_conn), do: :web
end
