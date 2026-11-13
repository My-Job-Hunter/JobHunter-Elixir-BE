defmodule Core.Inbound do
  @moduledoc """
  Forwarded mail's intake (AQ-09 §6, §8, §11.4): the provider's webhook
  (`POST /inbound/email`, Postmark's JSON) and the dev route
  (`POST /dev/inbound {to, eml}`) hand each delivery here, and **every
  delivery accepted is logged** in `inbound_messages` with its outcome
  and answered 200, so the provider never retries what can never land
  (QP9-7):

  1. **The provider's retry** — the same `(provider, provider_message_id)`
     — answers `duplicate` and adds nothing, not even a row.
  2. **The address** names a live email channel by its token
     (`Core.Inbound.Address`), else `unknown_address`. A rate limit per
     address (`per_minute`, 60) refuses a flood with 429.
  3. **The raw mail** is read by P6's parser, else `unreadable`.
  4. **Gmail's forwarding check** (`Core.Inbound.Gmail`) is kept on the
     channel (`channel_confirmations`), its owners told
     (`conversations.forwarding_confirm`), never a conversation:
     `gmail_confirmation`.
  5. **The same mail by another route** — P6's key, `rfc:<Message-ID>` —
     is `duplicate`, naming the message it is.
  6. Otherwise it **lands** (`Core.Conversations.Forward`), as the system
     for the channel's organisation: `landed`.

  A body over the webhook's cap never reaches here: `Api.Endpoint`
  refuses it (413) and logs `too_large` (`too_large/3`).

  **Config** (`config :core, :inbound`): `address` (with `{token}`),
  `user` and `password` (the webhook's basic auth; without a password it
  is off, 503 `inbound_off`), `max_bytes`, `per_minute`.
  """

  alias Core.Conversations.{Eml, Forward}
  alias Core.Inbound.{Address, Gmail, Postmark}
  alias Core.Notifications
  alias Core.Plugs.RateLimit
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Channels
  alias Data.Conversations, as: ConversationStore
  alias Data.Inbound, as: Store
  alias Data.Scope

  @type answer :: %{outcome: atom(), message_id: binary() | nil, conversation_id: binary() | nil}

  # ── Config ──────────────────────────────────────────────────────────────────

  defp config(key), do: :core |> Application.get_env(:inbound, []) |> Keyword.get(key)

  @doc "An email channel's forwarding address, from its token and config."
  @spec address(String.t() | nil) :: String.t() | nil
  def address(nil), do: nil
  def address(token), do: Address.build(config(:address), token)

  @doc "The webhook's body cap in bytes (30 MB)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: config(:max_bytes) || 30 * 1024 * 1024

  @doc """
  Whether a request's basic-auth pair is the configured one, compared in
  constant time: `:ok`, `{:error, :inbound_off}` (no password configured)
  or `{:error, :inbound_unauthorised}`.
  """
  @spec authorise(String.t() | nil, String.t() | nil) :: :ok | {:error, atom()}
  def authorise(user, password) do
    case {config(:user), config(:password)} do
      {_user, missing} when missing in [nil, ""] ->
        {:error, :inbound_off}

      {want_user, want_password} ->
        # Both compared, always, so the time says nothing about which was wrong.
        same_user = Plug.Crypto.secure_compare(to_string(user), to_string(want_user))
        same_password = Plug.Crypto.secure_compare(to_string(password), want_password)
        if same_user and same_password, do: :ok, else: {:error, :inbound_unauthorised}
    end
  end

  # ── The deliveries ──────────────────────────────────────────────────────────

  @doc "`POST /inbound/email`: Postmark's JSON (`bytes` the request's size)."
  @spec postmark(Scope.t(), map(), non_neg_integer(), DateTime.t()) ::
          {:ok, answer()} | {:error, term()}
  def postmark(%Scope{via: :system} = scope, body, bytes, %DateTime{} = now) do
    {:ok, read} = Postmark.read(body)
    deliver(scope, Map.merge(read, %{provider: :postmark, bytes: bytes}), now)
  end

  @doc """
  `POST /dev/inbound {to, eml}`: the same intake, `provider: dev`; the
  delivery's id is a hash of the address and the bytes, so the same
  delivery twice is the provider's retry.
  """
  @spec dev(Scope.t(), map(), DateTime.t()) :: {:ok, answer()} | {:error, term()}
  def dev(%Scope{via: :system} = scope, params, %DateTime{} = now) do
    to = params["to"] || params[:to]
    raw = params["eml"] || params[:eml]

    cond do
      not is_binary(to) or to == "" ->
        {:error, {:missing, [:to]}}

      not is_binary(raw) or raw == "" ->
        {:error, {:missing, [:eml]}}

      true ->
        id =
          Base.encode16(:crypto.hash(:sha256, String.downcase(to) <> "\n" <> raw), case: :lower)

        deliver(
          scope,
          %{provider: :dev, provider_message_id: id, to: to, raw: raw, bytes: byte_size(raw)},
          now
        )
    end
  end

  @doc "A body over the cap (`Api.Endpoint`, after the credentials passed): logged `too_large`."
  @spec too_large(Scope.t(), non_neg_integer(), DateTime.t()) :: :ok
  def too_large(%Scope{via: :system}, bytes, %DateTime{} = now) do
    {:ok, _row} =
      Store.log(%{provider: :postmark, outcome: :too_large, bytes: bytes, received_at: now})

    :ok
  end

  defp deliver(scope, d, now) do
    case Store.delivery(d.provider, d.provider_message_id) do
      %{} = held ->
        {:ok, answer(:duplicate, held.message_id)}

      nil ->
        with :ok <- throttle(d.to), do: {:ok, accepted(scope, d, now)}
    end
  end

  defp throttle(nil), do: :ok

  defp throttle(to) do
    case RateLimit.check("inbound:" <> Address.bare(to), 60_000, config(:per_minute) || 60) do
      :allow -> :ok
      {:deny, ms} -> {:error, {:rate_limited, max(div(ms, 1000), 1)}}
    end
  end

  defp accepted(scope, d, now) do
    channel = Channels.by_token(Address.token(config(:address), d.to))

    row = %{
      provider: d.provider,
      provider_message_id: d.provider_message_id,
      to_address: d.to && Address.bare(d.to),
      bytes: d.bytes,
      received_at: now,
      organisation_id: channel && channel.customer.organisation_id,
      channel_id: channel && channel.id
    }

    {outcome, message, rfc} = outcome(scope, channel, d.raw, now)

    {:ok, _row} =
      Store.log(
        Map.merge(row, %{outcome: outcome, message_id: message && message.id, rfc_message_id: rfc})
      )

    answer(outcome, message && message.id, message && message.conversation_id)
  end

  defp outcome(_scope, nil, _raw, _now), do: {:unknown_address, nil, nil}
  defp outcome(_scope, _channel, nil, _now), do: {:unreadable, nil, nil}

  defp outcome(_scope, channel, raw, now) do
    scope = Scope.system(Data.Organisations.get(channel.customer.organisation_id))

    case Eml.parse(raw) do
      {:ok, mail} -> read(scope, channel, raw, mail, now)
      {:error, :unreadable} -> {:unreadable, nil, nil}
    end
  end

  defp read(scope, channel, raw, mail, now) do
    case Gmail.confirmation(mail) do
      {:ok, check} ->
        :ok = confirmation(scope, channel, check, now)
        {:gmail_confirmation, nil, mail.message_id}

      :no ->
        key = key(mail, raw)
        org = Scope.organisation_id(scope)

        case ConversationStore.message_by_key(org, key) do
          nil -> land(scope, channel, raw, mail, key, now)
          held -> {:duplicate, held, mail.message_id}
        end
    end
  end

  defp land(scope, channel, raw, mail, key, now) do
    case Forward.land(scope, channel, raw, mail, key, now) do
      {:ok, message} ->
        {:landed, message, mail.message_id}

      {:error, _why} ->
        # Another delivery of the same mail may have landed meanwhile.
        case ConversationStore.message_by_key(Scope.organisation_id(scope), key) do
          nil -> {:unreadable, nil, mail.message_id}
          held -> {:duplicate, held, mail.message_id}
        end
    end
  end

  # P6's key: the Message-ID, else a hash of the bytes.
  defp key(%{message_id: id}, _raw) when is_binary(id), do: "rfc:" <> id
  defp key(_mail, raw), do: "eml:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  defp answer(outcome, message_id, conversation_id \\ nil),
    do: %{outcome: outcome, message_id: message_id, conversation_id: conversation_id}

  @doc "The log's rows received more than 30 days before `now`, deleted (QP9-8). Answers how many."
  @spec sweep(Scope.t(), DateTime.t()) :: non_neg_integer()
  def sweep(%Scope{via: :system}, %DateTime{} = now),
    do: Store.sweep_for_system(DateTime.add(now, -30, :day))

  # ── Gmail's check ───────────────────────────────────────────────────────────

  # Kept on the channel; the profiles' owners and the customer told
  # (`conversations.forwarding_confirm`, deduped by channel and code).
  defp confirmation(scope, channel, check, now) do
    {:ok, nil} = Write.commit(fn -> {:ok, nil, confirmed(scope, channel, check, now)} end)
    :ok
  end

  defp confirmed(scope, channel, %{code: code, url: url}, now) do
    {:ok, _check} =
      Store.put_confirmation(channel.id, %{code: code, confirm_url: url, received_at: now})

    owners =
      for %{profile: %{profile_members: members}} <- channel.profile_channels,
          m <- members,
          do: m.user_id

    customer = channel.customer
    address = address(channel.inbound_token)

    title =
      "Gmail asks to confirm forwarding for #{address}." <>
        if(code, do: " Code #{code}.", else: "")

    dedupe = "channel:#{channel.id}:confirm:#{code || url}"

    events =
      for {user_id, link} <-
            Enum.uniq_by(
              Enum.map(owners, &{&1, "/customers/#{customer.id}/channels"}) ++
                if(customer.user_id, do: [{customer.user_id, "/channels"}], else: []),
              &elem(&1, 0)
            ) do
        {:ok, row} =
          Notifications.ensure(scope, %{
            organisation_id: customer.organisation_id,
            user_id: user_id,
            notification_kind_key: "conversations.forwarding_confirm",
            actor_user_id: nil,
            title: title,
            link_path: link,
            dedupe_key: dedupe
          })

        if row.is_new, do: Realtime.to_user(user_id, "notification_created", %{id: row.id})
      end

    Enum.reject(events, &is_nil/1)
  end
end
