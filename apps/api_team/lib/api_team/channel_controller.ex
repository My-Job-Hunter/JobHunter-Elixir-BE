defmodule ApiTeam.ChannelController do
  @moduledoc "A customer's channels (AQ-01 §6.2)."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers.Channels

  action_fallback ApiShared.FallbackController

  def index(conn, %{"id" => customer_id}) do
    with {:ok, channels} <- Channels.list(conn.assigns.scope, customer_id),
         do: json(conn, Enum.map(channels, &CustomersJSON.channel/1))
  end

  def create(conn, %{"id" => customer_id} = params) do
    with {:ok, channel} <- Channels.create(conn.assigns.scope, customer_id, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.channel(channel))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, channel} <- Channels.get(conn.assigns.scope, id),
         do: json(conn, CustomersJSON.channel(channel))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, channel} <- Channels.update(conn.assigns.scope, id, Map.delete(params, "id")),
         do: json(conn, CustomersJSON.channel(channel))
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, channel} <- Channels.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.channel(channel))
  end

  @doc "*New address* (AQ-09 §11.4): a fresh forwarding address; the old one stops at once."
  def renew_address(conn, %{"id" => id}) do
    with {:ok, channel} <- Channels.renew_address(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.channel(channel))
  end
end
