defmodule ApiClient.CustomerController do
  @moduledoc """
  The customer's own record and "who serves me" (AQ-01 §6.3). The customer
  comes from `conn.assigns.scope` (`ApiClient.Plugs.CustomerScope`), never
  from params.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Customers
  alias Core.Customers.Portal
  alias Data.Scope

  action_fallback ApiShared.FallbackController

  def show(conn, _params) do
    scope = conn.assigns.scope

    with {:ok, customer} <- Customers.get(scope, Scope.customer_id(scope)),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def update(conn, params) do
    scope = conn.assigns.scope

    with {:ok, customer} <- Customers.update(scope, Scope.customer_id(scope), params),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def team(conn, _params) do
    with {:ok, teams} <- Portal.who_serves(conn.assigns.scope), do: json(conn, teams)
  end
end
