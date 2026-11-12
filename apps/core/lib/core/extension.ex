defmodule Core.Extension do
  @moduledoc """
  The Chrome extension's devices (AQ-05 §7, QP5-4, QP5-5): the one-time
  connect code the console mints, its exchange for a device and a Guardian
  pair, the device behind a token, and *Disconnect*. The acting profile is
  `Core.Extension.Context`, the selector documents `Core.Extension.Configs`,
  the misses `Core.Extension.Health`; the page's job and leads are
  `Core.Ingest.Extension`.

  **A device's tokens are Guardian's**, 1 h / 7 d rolling as a browser
  session's: `sid` is the device's id and `dev.app` is `ext`, so a device
  token works only on `/ext/v1` and no other token works there
  (`Core.Auth.Guardian.extension_token?/1`). Disconnecting deletes them —
  the next refresh fails — and sets `revoked_at`. Every connect and
  disconnect is audited, `via: extension` for the extension's own.
  """

  alias Core.Access
  alias Core.Access.Grants
  alias Core.Accounts.Device, as: Agent
  alias Core.Audit
  alias Core.Auth.Guardian
  alias Data.Accounts
  alias Data.Accounts.{User, UserToken}
  alias Data.Devices
  alias Data.Devices.Device
  alias Data.Repo
  alias Data.Scope

  @code_ttl_s 120
  @audited ~w(user_id name extension_version connected_at revoked_at revoked_by_user_id)a

  @doc "How long a connect code lives: two minutes (QP5-4)."
  def code_ttl_s, do: @code_ttl_s

  # ── Connecting ──────────────────────────────────────────────────────────────

  @doc """
  `POST /team/v1/devices/connect-codes`: a one-time code for the caller's
  extension, `%{code, expires_at}`. Any staff member; only its digest is
  kept (`user_tokens`, purpose `connect_extension`).
  """
  @spec connect_code(Scope.t(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_code(%Scope{} = scope, %DateTime{} = now, opts \\ []) do
    with :ok <- Access.why_not(scope, :connect, :extension) do
      expires_at = DateTime.add(now, @code_ttl_s, :second)

      {:ok, {code, _row}} =
        Accounts.create_token(scope.user, :connect_extension, expires_at, requested_ip: opts[:ip])

      {:ok, %{code: code, expires_at: expires_at}}
    end
  end

  @doc """
  `POST /ext/v1/session {code, extension_version}`: the code — live,
  unused, of a live staff account — becomes a device and its token pair,
  in one transaction. A dead, used or unknown code is `:token_invalid`
  (P1's 410), one answer for all three. `client` carries the request's
  `agent` (its `user-agent`), `ip` and `request_id`.

  Answers `%{device, tokens, scope}`, the scope the device acts with.
  """
  @spec connect(term(), map(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def connect(code, params, client, %DateTime{} = now) do
    with %UserToken{user: %User{} = user} = token <-
           Accounts.get_live_token(code, [:connect_extension], now) || {:error, :token_invalid},
         true <- User.active?(user) || {:error, :token_invalid},
         scope = Grants.scope_for(user, via: :extension, request_id: client[:request_id]),
         :ok <- staff(scope),
         {:ok, version} <- version(params) do
      Repo.transaction(fn -> exchange(scope, token, version, client, now) end)
    end
  end

  defp staff(scope) do
    case Access.why_not(scope, :connect, :extension) do
      :ok -> :ok
      {:error, _reason} -> {:error, :token_invalid}
    end
  end

  defp version(params) do
    case Utils.presence(to_string(params["extension_version"] || "")) do
      nil -> {:error, {:missing, [:extension_version]}}
      v when byte_size(v) > 20 -> {:error, {:invalid, %{"extension_version" => ["is too long"]}}}
      v -> {:ok, v}
    end
  end

  defp exchange(scope, token, version, client, now) do
    agent = client[:agent] |> to_string() |> String.slice(0, 300)

    with :ok <- Accounts.consume_token(token, now),
         {:ok, device} <-
           Devices.create(%{
             organisation_id: Scope.organisation_id(scope),
             user_id: Scope.user_id(scope),
             name: Agent.describe(%{"agent" => agent}) || "Chrome",
             agent: Utils.presence(agent),
             extension_version: version,
             connected_at: now,
             last_seen_at: now
           }) do
      {:ok, _event} = Audit.record(scope, "connected", device, after: snapshot(device), now: now)

      session = %{
        "sid" => device.id,
        "dev" => %{"app" => "ext", "agent" => String.slice(agent, 0, 200), "ip" => client[:ip]}
      }

      {:ok, tokens} = Guardian.tokens_for(scope.user, session)
      %{device: device, tokens: tokens, scope: scope}
    else
      :used -> Repo.rollback(:token_invalid)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # ── The device behind a token ───────────────────────────────────────────────

  @doc """
  The live device a token's `sid` names, for the person the scope is, who
  must be staff; `:unauthenticated` otherwise (AQ-05 §4: any `/ext/v1`
  route but `session`).
  """
  @spec live_device(Scope.t(), term()) :: {:ok, Device.t()} | {:error, :unauthenticated}
  def live_device(%Scope{} = scope, sid) do
    with :ok <- Access.why_not(scope, :use, :extension),
         %Device{} = device <- Devices.live(Scope.user_id(scope), sid) do
      {:ok, device}
    else
      _no -> {:error, :unauthenticated}
    end
  end

  @doc "The device was used: `last_seen_at` moves, at most once a minute."
  @spec seen(Scope.t(), Device.t(), DateTime.t()) :: :ok
  def seen(%Scope{}, %Device{} = device, %DateTime{} = now), do: Devices.seen(device, now)

  # ── Listing and disconnecting ───────────────────────────────────────────────

  @doc """
  `GET /team/v1/devices`: the caller's live devices, newest first;
  `all=true`, every live device of the organisation — the system admin's
  alone (404 for anyone else).
  """
  @spec list(Scope.t(), map()) :: {:ok, [Device.t()]} | {:error, term()}
  def list(%Scope{} = scope, params) do
    if params["all"] in [true, "true"] do
      with :ok <- Access.why_not(scope, :list_devices, :extension),
           do: {:ok, Devices.list(Scope.organisation_id(scope))}
    else
      with :ok <- Access.why_not(scope, :connect, :extension),
           do: {:ok, Devices.list(Scope.organisation_id(scope), user_id: Scope.user_id(scope))}
    end
  end

  @doc """
  *Disconnect* (`DELETE /team/v1/devices/:id`, `DELETE /ext/v1/session`):
  the owner or the system admin; anyone else, or a device already
  disconnected, finds nothing. The device's tokens are deleted — its next
  refresh fails — and `revoked_at` is set, with the audit row, in one
  transaction.
  """
  @spec disconnect(Scope.t(), term(), DateTime.t()) :: {:ok, Device.t()} | {:error, term()}
  def disconnect(%Scope{} = scope, id, %DateTime{} = now) do
    with %Device{revoked_at: nil} = device <-
           Devices.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :disconnect, {:device, device}) do
      Repo.transaction(fn ->
        _gone = Accounts.revoke_session(device.user_id, device.id)
        {:ok, revoked} = Devices.revoke(device, now, Scope.user_id(scope))

        {:ok, _event} =
          Audit.record(scope, "disconnected", revoked,
            before: snapshot(device),
            after: snapshot(revoked),
            now: now
          )

        revoked
      end)
    else
      %Device{} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp snapshot(device), do: Audit.snapshot(device, @audited)
end
