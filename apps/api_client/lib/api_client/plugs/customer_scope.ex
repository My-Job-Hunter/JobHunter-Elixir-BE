defmodule ApiClient.Plugs.CustomerScope do
  @moduledoc """
  Pins the portal's scope to the customer (JH-01 §5.1). Runs after
  `ApiShared.Plugs.Scope`: when `roles.customer_id` is nil — a staff account
  on the portal — the request is refused with `not_a_customer` (404 shape:
  "This sign-in is for customers"); otherwise the scope loses its staff
  roles (`Data.Scope.pin_to_customer/1`) and every controller below reads
  the customer from `conn.assigns.scope`, never from params.

  **Isolation by construction** (PLAN §0): no portal route can name another
  customer, because none takes a customer id and the scope holds one.
  """

  import Plug.Conn

  alias Data.Scope

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{scope: %Scope{} = scope}} = conn, _opts) do
    case Scope.pin_to_customer(scope) do
      %Scope{} = pinned -> assign(conn, :scope, pinned)
      nil -> refuse(conn)
    end
  end

  def call(conn, _opts), do: refuse(conn)

  defp refuse(conn) do
    conn
    |> ApiShared.FallbackController.call({:error, :not_a_customer})
    |> halt()
  end
end
