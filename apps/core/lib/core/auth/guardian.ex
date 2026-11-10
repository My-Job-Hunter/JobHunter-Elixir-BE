defmodule Core.Auth.Guardian do
  @moduledoc """
  JWT issuing and verification (copied from AutoCare).

  Access tokens last an hour, refresh tokens a week. `guardian_db` backs both
  so revocation is real: sign-out-everywhere and removing a person must
  actually invalidate a token, not wait for it to expire.

  The **user loader is injected** rather than aliased, so `core` does not
  compile-depend on a specific context and the auth layer stays testable
  without a database:

      config :core, Core.Auth.Guardian, user_loader: {Module, :function}

  The loader takes the token's subject (a user id) and answers `{:ok, user}`
  or `{:error, :not_found}`.

  The loader is `Core.Accounts.load_user/1`, which answers `:not_found` for
  a suspended or deactivated account too, so a token it still holds stops
  working at the next request.
  """

  use Guardian, otp_app: :core

  @access_ttl {1, :hour}
  @refresh_ttl {7, :day}

  @doc "How long an access token lives."
  def access_ttl, do: @access_ttl

  @doc "How long a refresh token lives."
  def refresh_ttl, do: @refresh_ttl

  @impl Guardian
  def subject_for_token(%{id: id}, _claims) when not is_nil(id), do: {:ok, to_string(id)}
  def subject_for_token(_resource, _claims), do: {:error, :invalid_subject}

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) when is_binary(id) do
    case load_user(id) do
      {:ok, user} -> {:ok, user}
      {:error, _reason} -> {:error, :resource_not_found}
    end
  end

  def resource_from_claims(_claims), do: {:error, :invalid_claims}

  @doc """
  An access/refresh pair. Keys are `snake_case` because the API is.

  Both tokens carry a session id (`sid`) that a refresh keeps, so a person's
  sessions can be listed and ended one at a time.
  """
  @spec tokens_for(struct() | map(), map()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t()}}
  def tokens_for(user, session \\ %{}) do
    # The device that signed in (`dev`: the app, the agent, the address), so
    # `/me/sessions` can say "Chrome on macOS".
    claims = %{
      "sid" => Map.get(session, "sid") || Ecto.UUID.generate(),
      "dev" => Map.get(session, "dev") || %{}
    }

    {:ok, access, _claims} = encode_and_sign(user, claims, token_type: "access", ttl: @access_ttl)

    {:ok, refresh, _claims} =
      encode_and_sign(user, claims, token_type: "refresh", ttl: @refresh_ttl)

    {:ok, %{access_token: access, refresh_token: refresh}}
  end

  @doc """
  Exchanges a refresh token for a new pair.

  The old refresh token is revoked in the same breath — a refresh token that
  survives its own use is a replay waiting to happen.

  Named `exchange_refresh_token` rather than `refresh` because `use Guardian`
  already defines `refresh/2`, which re-signs an existing token instead of
  issuing a fresh pair.
  """
  @spec exchange_refresh_token(String.t()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t()}} | {:error, atom()}
  def exchange_refresh_token(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{"typ" => "refresh"}),
         {:ok, user} <- resource_from_claims(claims),
         {:ok, _claims} <- revoke(refresh_token) do
      tokens_for(user, Map.take(claims, ["sid", "dev"]))
    else
      {:error, _reason} -> {:error, :invalid_refresh_token}
    end
  end

  def exchange_refresh_token(_token), do: {:error, :invalid_refresh_token}

  # ─── `guardian_db`'s hooks ──────────────────────────────────────────────────
  #
  # `use Guardian` does not install these, and without them `revoke/1` deletes
  # nothing and a token stays valid until it expires (AutoCare found this the
  # hard way, `PA6`). `on_verify` is what makes revocation *take effect*: a
  # token whose row has gone stops verifying, for one indexed read per
  # authenticated request.

  @impl Guardian
  def after_encode_and_sign(resource, claims, token, _options) do
    with {:ok, _stored} <-
           Guardian.DB.after_encode_and_sign(resource, claims["typ"], claims, token) do
      {:ok, token}
    end
  end

  @impl Guardian
  def on_verify(claims, token, _options) do
    with {:ok, _found} <- Guardian.DB.on_verify(claims, token) do
      {:ok, claims}
    end
  end

  @impl Guardian
  def on_refresh({old_token, old_claims}, {new_token, new_claims}, _options) do
    with {:ok, _old, _new} <-
           Guardian.DB.on_refresh({old_token, old_claims}, {new_token, new_claims}) do
      {:ok, {old_token, old_claims}, {new_token, new_claims}}
    end
  end

  @impl Guardian
  def on_revoke(claims, token, _options) do
    with {:ok, _removed} <- Guardian.DB.on_revoke(claims, token) do
      {:ok, claims}
    end
  end

  @doc """
  Ends **every** session this person has: deletes their rows from
  `guardian_tokens`, so every access and refresh token they hold stops
  verifying — on this device and on the ones they are not holding.
  """
  @spec revoke_all_for(struct() | map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_for(%{id: id}) when not is_nil(id), do: Guardian.DB.revoke_all(to_string(id))
  def revoke_all_for(_resource), do: {:error, :invalid_subject}

  # Configured, not aliased: `config :core, Core.Auth.Guardian, user_loader:`.
  defp load_user(id) do
    case Application.get_env(:core, __MODULE__)[:user_loader] do
      {module, function} -> apply(module, function, [id])
      nil -> raise "Core.Auth.Guardian needs a :user_loader in config"
    end
  end
end
