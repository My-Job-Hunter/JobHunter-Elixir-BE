defmodule Notifire.Push do
  @moduledoc """
  Web Push (AQ-08 §7.6, QP8-13; copied from mCart's): a payload sent to
  every browser a person turned push on in one app — staff on `team`, a
  customer on `client` — encrypted for each browser (RFC 8291,
  `aes128gcm`) and signed for the push service (RFC 8292, VAPID, ES256),
  with `:crypto` and Req: no new dependency. TTL one day, urgency high.

  A browser the push service says is gone (404, 410) is deleted; any other
  refusal marks it failed and leaves it for the next one. **Without a VAPID
  pair** (`config :notifire, :web_push`) nothing is sent: `configured?/0`
  is false and the sweep skips the row (`no_target`), never failing it.

  **The dev outbox** (QP8-16): each payload is kept for `/dev/push/json`
  (`Notifire.Push.Outbox`). Dev keeps it and still sends; test only keeps
  it (`config :notifire, :push_send, false`), unless a test asks to send
  (`send: true`) to its stand-in endpoint (`:push_req_options`).
  """

  alias Data.Notifications.PushSubscriptions
  alias Notifire.Push.Outbox

  require Logger

  @ttl_s 86_400
  @record_size 4096

  @doc "Whether this server can send push (a VAPID pair is set)."
  @spec configured?() :: boolean()
  def configured?, do: keys() != nil

  @doc "The public key a browser subscribes with (base64url), or `nil`."
  @spec public_key() :: String.t() | nil
  def public_key, do: keys() && keys().public_key

  @doc """
  Sends `payload` (`%{title, body, tag, url}`, as JSON) to the person's
  browsers on `app`. Answers `%{sent, gone, failed, error}`: how many took
  it, how many were gone (and deleted), how many refused, and the last
  refusal in a few words (never the payload). `opts[:send]` overrides
  `config :notifire, :push_send`.
  """
  @spec deliver(binary(), atom(), map(), DateTime.t(), keyword()) :: map()
  def deliver(user_id, app, payload, %DateTime{} = now, opts \\ []) do
    tally = %{sent: 0, gone: 0, failed: 0, error: nil}
    send? = Keyword.get(opts, :send, Application.get_env(:notifire, :push_send, true))

    case keys() do
      nil ->
        tally

      vapid ->
        body = Jason.encode!(payload)

        user_id
        |> PushSubscriptions.for_user([app])
        |> Enum.reduce(tally, &push_one(&1, &2, {payload, body, vapid, send?}, now))
    end
  end

  # One browser: kept in the outbox, then sent unless this is the test's
  # record-only mode.
  defp push_one(s, tally, {payload, body, vapid, send?}, now) do
    Outbox.record(%{
      at: now,
      user_id: s.user_id,
      app: s.app,
      endpoint: s.endpoint,
      payload: payload
    })

    outcome = if send?, do: send_one(s, body, vapid), else: :ok
    count(outcome, s, tally, now)
  end

  defp count(:ok, s, tally, now) do
    PushSubscriptions.mark(s.id, :used, now)
    Map.update!(tally, :sent, &(&1 + 1))
  end

  defp count(:gone, s, tally, _now) do
    PushSubscriptions.delete(s.id)
    Map.update!(tally, :gone, &(&1 + 1))
  end

  defp count({:error, why}, s, tally, now) do
    Logger.warning("push to #{s.id} failed: #{why}")
    PushSubscriptions.mark(s.id, :failed, now)
    %{tally | failed: tally.failed + 1, error: why}
  end

  defp send_one(s, body, vapid) do
    with {:ok, p256dh} <- decode(s.p256dh),
         {:ok, auth} <- decode(s.auth),
         {:ok, encrypted} <- encrypt(body, p256dh, auth) do
      uri = URI.parse(s.endpoint)

      headers = [
        {"ttl", Integer.to_string(@ttl_s)},
        {"urgency", "high"},
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"authorization", "vapid t=#{jwt(uri, vapid)}, k=#{vapid.public_key}"}
      ]

      options =
        [headers: headers, body: encrypted, retry: false, receive_timeout: 10_000]
        |> Keyword.merge(Application.get_env(:notifire, :push_req_options, []))

      case Req.post(s.endpoint, options) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} when status in [404, 410] -> :gone
        {:ok, %{status: status}} -> {:error, "push refused: #{status}"}
        {:error, reason} -> {:error, "push failed: #{Exception.message(reason)}"}
      end
    else
      {:error, {:encrypt, why}} -> {:error, "push failed: #{why}"}
      _undecodable -> {:error, "push failed: the browser's keys don't decode"}
    end
  end

  @doc false
  # RFC 8291: the payload encrypted for the browser's key and auth secret, in one record.
  def encrypt(plaintext, ua_public, auth_secret) do
    {as_public, as_private} = :crypto.generate_key(:ecdh, :prime256v1)
    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    salt = :crypto.strong_rand_bytes(16)

    prk_key = hmac(auth_secret, shared)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac(salt, ikm)
    cek = binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

    # The last (and only) record ends with the 0x02 delimiter.
    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

    header = salt <> <<@record_size::unsigned-big-32, byte_size(as_public)::8>> <> as_public
    {:ok, header <> cipher <> tag}
  rescue
    e -> {:error, {:encrypt, Exception.message(e)}}
  end

  # RFC 8292: a JWT for the push service's origin, signed with the server's
  # private key (ES256). **The real time, never the dev clock**: the push
  # service checks `exp` against its own.
  defp jwt(uri, vapid) do
    header = b64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))
    exp = System.os_time(:second) + 12 * 3600

    claims =
      b64(Jason.encode!(%{aud: "#{uri.scheme}://#{uri.host}", exp: exp, sub: vapid.subject}))

    input = header <> "." <> claims
    {:ok, private} = decode(vapid.private_key)
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :prime256v1])
    input <> "." <> b64(raw_signature(der))
  end

  # A DER ECDSA signature as the 64 bytes JOSE wants: r and s, each left-padded to 32.
  defp raw_signature(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad(:binary.encode_unsigned(r)) <> pad(:binary.encode_unsigned(s))
  end

  defp pad(bin) when byte_size(bin) >= 32, do: binary_part(bin, byte_size(bin) - 32, 32)
  defp pad(bin), do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp decode(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.decode64(s)
    end
  end

  defp decode(_s), do: :error

  defp keys do
    kw = Application.get_env(:notifire, :web_push) || []

    if kw[:public_key] && kw[:private_key] do
      %{
        public_key: kw[:public_key],
        private_key: kw[:private_key],
        subject: kw[:subject] || "mailto:support@autoqare.com"
      }
    end
  end
end
