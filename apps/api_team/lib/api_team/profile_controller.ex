defmodule ApiTeam.ProfileController do
  @moduledoc """
  Profiles (JH-01 §6.2). `PATCH /profiles/:id` goes to the pitch verb or the
  facts verb by its fields (`Core.Customers.Profiles.update/3`); a body
  that mixes the two is `validation_failed`.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers.Profiles

  action_fallback ApiShared.FallbackController

  def index(conn, %{"id" => customer_id}) do
    with {:ok, profiles} <- Profiles.list(conn.assigns.scope, customer_id),
         do: json(conn, Enum.map(profiles, &CustomersJSON.profile/1))
  end

  def create(conn, %{"id" => customer_id} = params) do
    with {:ok, profile} <- Profiles.create(conn.assigns.scope, customer_id, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.profile(profile))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, profile} <- Profiles.get(conn.assigns.scope, id),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.update(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, profile} <- Profiles.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def put_owners(conn, %{"id" => id} = params) do
    with {:ok, profile} <-
           Profiles.put_owners(conn.assigns.scope, id, params["user_ids"], Clock.now()),
         do: json(conn, CustomersJSON.profile(profile))
  end

  def put_skills(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.put_skills(conn.assigns.scope, id, skills(params)),
         do: json(conn, CustomersJSON.profile(profile))
  end

  # The body is the array itself (§6.2) or `{skills: [...]}`; Phoenix wraps a
  # bare array under `_json`.
  defp skills(%{"_json" => rows}), do: rows
  defp skills(%{"skills" => rows}), do: rows
  defp skills(_params), do: nil

  def put_channels(conn, %{"id" => id} = params) do
    with {:ok, profile} <- Profiles.put_channels(conn.assigns.scope, id, params["channel_ids"]),
         do: json(conn, CustomersJSON.profile(profile))
  end
end
