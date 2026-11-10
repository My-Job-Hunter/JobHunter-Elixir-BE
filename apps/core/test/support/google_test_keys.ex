defmodule Core.Auth.GoogleTestKeys do
  @moduledoc """
  The tests' own signing key, standing in for Google's JWKS
  (`config :core, :google, keys: Core.Auth.GoogleTestKeys`). `token/2` signs
  a claim set the way Google would, so the verification path is tested end
  to end without the network.
  """

  @behaviour Core.Auth.Google.Keys

  alias Core.Auth.Google

  @kid "test-key"
  @audience "test-client.apps.googleusercontent.com"

  @impl true
  def fetch, do: {:ok, %{@kid => public_key()}}

  @doc "The audience the test config names."
  def audience, do: @audience

  @doc "A Google-shaped ID token for `email`, signed with the test key. `overrides` replaces claims."
  def token(email, overrides \\ %{}) do
    claims =
      Map.merge(
        %{
          "iss" => "https://accounts.google.com",
          "aud" => @audience,
          "sub" => "google-sub-#{email}",
          "email" => email,
          "email_verified" => true,
          "name" => "Google Person",
          "exp" => System.system_time(:second) + 600
        },
        overrides
      )

    Google.sign(private_key(), overrides["kid"] || @kid, claims)
  end

  # Made once per test run: 2048-bit RSA takes a moment.
  defp private_key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        key = JOSE.JWK.generate_key({:rsa, 2048})
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end

  defp public_key, do: JOSE.JWK.to_public(private_key())
end
