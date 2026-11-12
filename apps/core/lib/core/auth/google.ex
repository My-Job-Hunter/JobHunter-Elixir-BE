defmodule Core.Auth.Google do
  @moduledoc """
  *Continue with Google* (AQ-01 QP1-5): proves a Google ID token, and nothing
  else. What an account does with a proved token is `Core.Accounts`.

  **A token is believed only if every check passes:** Google's signature,
  checked against Google's published keys (`Core.Auth.Google.Keys.Google`);
  Google as the issuer; this app's client id as the audience; not expired;
  an address Google says it has verified. One answer for every failure,
  `:invalid_google_token`, so a caller learns nothing about which check
  failed.

  ## The dev stand-in

  Real Google needs a client id only the owner can create. Until
  `GOOGLE_CLIENT_ID` is set, a dev build accepts `id_token = "dev:<email>"`
  and believes it on the same terms as Google's, with the subject
  `"dev:<email>"`. It is on only when `config :core, :google, stand_in: true`
  (dev) **and** no client id is set; `config/runtime.exs` turns it off in
  production whatever the config says.
  """

  alias Core.Auth.Google.Keys

  @google_issuers ["accounts.google.com", "https://accounts.google.com"]
  @stand_in_prefix "dev:"

  @type claims :: %{subject: String.t(), email: String.t(), name: String.t() | nil}

  @doc "What the sign-in page needs to know: a client id, or whether the stand-in is on."
  @spec settings() :: %{client_id: String.t() | nil, stand_in: boolean()}
  def settings, do: %{client_id: client_id(), stand_in: stand_in?()}

  @doc "Whether the dev stand-in is on."
  @spec stand_in?() :: boolean()
  def stand_in?, do: Keyword.get(config(), :stand_in, false) == true and is_nil(client_id())

  @doc "Proves an ID token. One error for every way it can fail."
  @spec verify(String.t() | nil, DateTime.t()) ::
          {:ok, claims()} | {:error, :invalid_google_token}
  def verify(token, now)

  def verify(@stand_in_prefix <> email, _now) do
    email = email |> String.trim() |> String.downcase()

    if stand_in?() and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email),
      do: {:ok, %{subject: @stand_in_prefix <> email, email: email, name: nil}},
      else: {:error, :invalid_google_token}
  end

  def verify(token, now) when is_binary(token) and byte_size(token) > 0 do
    case client_id() do
      nil -> {:error, :invalid_google_token}
      audience -> check(token, google_keys(), audience, now)
    end
  end

  def verify(_token, _now), do: {:error, :invalid_google_token}

  @doc false
  # Signs claims with a key, `kid` in the header. Public for the tests' keys.
  @spec sign(JOSE.JWK.t(), String.t(), map()) :: String.t()
  def sign(jwk, kid, claims) do
    jwk
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp check(token, keys, audience, now) do
    with {:ok, kid} <- kid(token),
         {:ok, jwk} <- Map.fetch(keys, kid),
         {true, %JOSE.JWT{fields: fields}, _jws} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token),
         true <- fields["iss"] in @google_issuers,
         true <- audience?(fields["aud"], audience),
         true <- is_integer(fields["exp"]) and fields["exp"] > DateTime.to_unix(now),
         true <- fields["email_verified"] in [true, "true"],
         email when is_binary(email) <- fields["email"],
         subject when is_binary(subject) <- fields["sub"] do
      {:ok,
       %{subject: subject, email: String.downcase(email), name: blank_to_nil(fields["name"])}}
    else
      _failed -> {:error, :invalid_google_token}
    end
  rescue
    # A token that is not even a JWT is the same answer as a forged one.
    _malformed -> {:error, :invalid_google_token}
  end

  defp kid(token) do
    case token |> JOSE.JWS.peek_protected() |> Jason.decode() do
      {:ok, %{"kid" => kid}} when is_binary(kid) -> {:ok, kid}
      _other -> :error
    end
  end

  defp audience?(audience, expected) when is_binary(audience), do: audience == expected
  defp audience?(audiences, expected) when is_list(audiences), do: expected in audiences
  defp audience?(_audience, _expected), do: false

  defp google_keys do
    case keys_module().fetch() do
      {:ok, keys} -> keys
      {:error, _reason} -> %{}
    end
  end

  defp config, do: Application.get_env(:core, :google, [])
  defp client_id, do: blank_to_nil(Keyword.get(config(), :client_id))
  defp keys_module, do: Keyword.get(config(), :keys, Keys.Google)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
