defmodule Api.UserSocket do
  @moduledoc """
  The one socket, at `/socket` (PLAN §15.6; AQ-01 §6.4).

  `connect/3` verifies an **access** token passed as `token` and assigns
  `user_id`; **no reason is given on refusal** — a socket that explains why
  it refused is a probe for whether an account exists. `id/1` is
  `"user_socket:<user_id>"`, so sign-out-everywhere
  (`Core.Accounts.logout_all/1`) drops every live socket the person has.

  **The channels** (AQ-02 §7.4), beside it in `api` because a channel is
  transport; who may join and which events a change sends are
  `Core.Realtime`'s:

  | Topic | Channel |
  |---|---|
  | `user:<id>` | `Api.UserChannel` |
  | `team:<id>` | `Api.TeamChannel` |
  | `customer:<id>` | `Api.CustomerChannel` |
  | `lead:<id>` | `Api.LeadChannel` (AQ-04B §8.3) |
  """

  use Phoenix.Socket

  channel "user:*", Api.UserChannel
  channel "team:*", Api.TeamChannel
  channel "customer:*", Api.CustomerChannel
  channel "lead:*", Api.LeadChannel

  alias Core.Auth.Guardian

  @impl Phoenix.Socket
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Guardian.resource_from_token(token, %{"typ" => "access"}) do
      {:ok, user, _claims} -> {:ok, assign(socket, :user_id, user.id)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @doc "Identifies the socket for `Api.Endpoint.broadcast/3`'s `disconnect`."
  @impl Phoenix.Socket
  def id(%Phoenix.Socket{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
