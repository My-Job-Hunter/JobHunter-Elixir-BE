defmodule ApiClient.ProfileController do
  @moduledoc """
  The customer's own profiles (AQ-01 §6.3): pitch and facts both allowed
  (Q28), one at a time per `PATCH` like the console. Another customer's
  profile answers 404: the scope is pinned, and `Core.Access` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Customers.Profiles
  alias Data.Scope

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    scope = conn.assigns.scope

    with {:ok, profiles} <- Profiles.list(scope, Scope.customer_id(scope)),
         do: json(conn, Enum.map(profiles, &CustomersJSON.profile/1))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, profile} <- Profiles.get(conn.assigns.scope, id),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.update(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def put_skills(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.put_skills(conn.assigns.scope, id, skills(params)),
         do: json(conn, CustomersJSON.profile(profile))
  end

  defp skills(%{"_json" => rows}), do: rows
  defp skills(%{"skills" => rows}), do: rows
  defp skills(_params), do: nil

  def put_channels(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.put_channels(conn.assigns.scope, id, params["channel_ids"]),
         do: json(conn, CustomersJSON.profile(profile))
  end
end
