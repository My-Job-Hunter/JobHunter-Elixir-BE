defmodule ApiClient.ChannelController do
  @moduledoc "The customer's own channels (AQ-01 §6.3)."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers.Channels
  alias Data.Scope

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    scope = conn.assigns.scope

    with {:ok, channels} <- Channels.list(scope, Scope.customer_id(scope)),
         do: json(conn, Enum.map(channels, &CustomersJSON.channel/1))
  end

  def create(conn, params) do
    scope = conn.assigns.scope

    with {:ok, channel} <- Channels.create(scope, Scope.customer_id(scope), params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.channel(channel))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, channel} <- Channels.update(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, CustomersJSON.channel(channel))
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, channel} <- Channels.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.channel(channel))
  end
end
