defmodule Core.Auth.GuardianTest do
  @moduledoc """
  Issuing, exchanging and revoking, against `guardian_tokens`.
  """

  use Core.CoreCase, async: true

  alias Core.Auth.Guardian

  test "tokens live an hour, refresh tokens a week" do
    assert Guardian.access_ttl() == {1, :hour}
    assert Guardian.refresh_ttl() == {7, :day}
  end

  test "the subject is the resource's id, as a string" do
    assert Guardian.subject_for_token(%{id: "0193c1d2"}, %{}) == {:ok, "0193c1d2"}
    assert Guardian.subject_for_token(%{id: nil}, %{}) == {:error, :invalid_subject}
    assert Guardian.subject_for_token(%{}, %{}) == {:error, :invalid_subject}
  end

  test "an unknown subject resolves to nobody" do
    assert Guardian.resource_from_claims(%{"sub" => Ecto.UUID.generate()}) ==
             {:error, :resource_not_found}

    assert Guardian.resource_from_claims(%{}) == {:error, :invalid_claims}
  end

  test "a pair carries one session id and the device, and verifies to the user" do
    user = user_fixture()

    {:ok, tokens} = Guardian.tokens_for(user, %{"dev" => %{"app" => "team"}})
    {:ok, access} = Guardian.decode_and_verify(tokens.access_token, %{"typ" => "access"})
    {:ok, refresh} = Guardian.decode_and_verify(tokens.refresh_token, %{"typ" => "refresh"})

    assert access["sid"] == refresh["sid"]
    assert access["dev"] == %{"app" => "team"}
    assert {:ok, loaded, _claims} = Guardian.resource_from_token(tokens.access_token)
    assert loaded.id == user.id
  end

  test "exchanging a refresh token revokes it and keeps the session id" do
    user = user_fixture()
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, old} = Guardian.decode_and_verify(tokens.refresh_token)

    {:ok, fresh} = Guardian.exchange_refresh_token(tokens.refresh_token)
    {:ok, new} = Guardian.decode_and_verify(fresh.refresh_token)

    assert new["sid"] == old["sid"]

    assert Guardian.exchange_refresh_token(tokens.refresh_token) ==
             {:error, :invalid_refresh_token}

    assert Guardian.exchange_refresh_token("not-a-token") == {:error, :invalid_refresh_token}
    assert Guardian.exchange_refresh_token(nil) == {:error, :invalid_refresh_token}
  end

  test "an access token is not a refresh token" do
    {:ok, tokens} = Guardian.tokens_for(user_fixture())

    assert Guardian.exchange_refresh_token(tokens.access_token) ==
             {:error, :invalid_refresh_token}
  end

  test "revoke_all_for ends every token the person holds" do
    user = user_fixture()
    {:ok, one} = Guardian.tokens_for(user)
    {:ok, two} = Guardian.tokens_for(user)

    assert {:ok, _count} = Guardian.revoke_all_for(user)

    for token <- [one.access_token, one.refresh_token, two.access_token] do
      assert {:error, _reason} = Guardian.decode_and_verify(token)
    end
  end
end
