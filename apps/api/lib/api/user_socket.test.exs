defmodule Api.UserSocketTest do
  @moduledoc """
  The socket accepts an access token and nothing else (JH-01 §6.4), through
  `Phoenix.ChannelTest`, which runs the real `connect/3` the transport runs.
  """

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian

  test "refuses a connection with no token, a bad token, and a refresh token" do
    user = user_fixture()
    {:ok, tokens} = Guardian.tokens_for(user)

    assert :error = connect(Api.UserSocket, %{})
    assert :error = connect(Api.UserSocket, %{"token" => "forged"})
    assert :error = connect(Api.UserSocket, %{"token" => tokens.refresh_token})
  end

  test "connects with an access token and is identified by the user" do
    user = user_fixture()
    {:ok, tokens} = Guardian.tokens_for(user)

    assert {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    assert socket.assigns.user_id == user.id
    assert Api.UserSocket.id(socket) == "user_socket:#{user.id}"
  end

  test "a revoked token no longer connects" do
    user = user_fixture()
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, _count} = Guardian.revoke_all_for(user)

    assert :error = connect(Api.UserSocket, %{"token" => tokens.access_token})
  end

  test "a socket with nobody has no id" do
    assert Api.UserSocket.id(%Phoenix.Socket{}) == nil
  end
end
