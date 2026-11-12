defmodule ApiClient.LeadController do
  @moduledoc """
  *My applications* in the portal (AQ-04A §8.2), on the scope pinned to the
  customer: their leads from every team, a lead's sheet in the customer's
  view (§8.4; another customer's lead is 404), *I applied* (`{from,
  applied_at?, applied_via?}`) and *Suggested for you*. The same
  `Core.Leads.*` functions as the console; `Core.Access` decides, and the
  customer's view is cut in the context.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads
  alias Core.Leads.{Act, Portal}

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    with {:ok, list} <- Portal.list(conn.assigns.scope, Clock.now()),
         do: json(conn, LeadsJSON.customer_list(list))
  end

  def show(conn, %{"id" => id}), do: sheet(conn, Leads.get(conn.assigns.scope, id, Clock.now()))

  def applied(conn, %{"id" => id} = params),
    do: sheet(conn, Act.portal_applied(conn.assigns.scope, id, params, Clock.now()))

  def suggestions(conn, _params) do
    with {:ok, list} <- Portal.suggestions(conn.assigns.scope, Clock.now()),
         do: json(conn, LeadsJSON.suggestions(list))
  end

  defp sheet(conn, {:ok, sheet}), do: json(conn, LeadsJSON.customer_sheet(sheet))
  defp sheet(_conn, error), do: error
end
