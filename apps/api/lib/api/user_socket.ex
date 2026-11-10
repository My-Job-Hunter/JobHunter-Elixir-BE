defmodule Api.UserSocket do
  @moduledoc """
  The one socket, at `/socket` (PLAN §15.6; JH-01 §6.4).

  `connect/3` verifies an **access** token passed as `token` and assigns
  `user_id`; **no reason is given on refusal** — a socket that explains why
  it refused is a probe for whether an account exists. `id/1` is
  `"user_socket:<user_id>"`, so sign-out-everywhere
  (`Core.Accounts.logout_all/1`) drops every live socket the person has.

  **No channel yet**: the first, `user:<id>`, comes with the bell in P2.
  Channels live in `core`, which owns the domain; this module is transport.
  """

  use Phoenix.Socket

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
