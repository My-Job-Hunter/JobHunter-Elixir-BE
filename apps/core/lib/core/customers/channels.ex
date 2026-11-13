defmodule Core.Customers.Channels do
  @moduledoc """
  A customer's channels (AQ-01 §4.3, §6.2, §6.3): the accounts the team
  works through. Every staff role of a serving team has full run of them,
  and so does the customer (§5.3). **Nothing here stores a credential**
  (PLAN Q3): `operated_by` says who holds the login.

  **An email channel's forwarding** (AQ-09 §6.1, §11.4): every answer
  carries `forwarding` — `{address, last_inbound_at, confirmation: {code,
  url, received_at}?, can_renew}` on an email channel, `nil` otherwise —
  seen by whoever sees the channel (staff serving the customer, the
  customer their own). *New address* (`renew_address/3`) replaces the
  token at once (QP9-6): the customer's team leads, the owners of the
  profiles it serves, the system admin, and the customer
  (`Core.Access.Channels`).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Core.Inbound
  alias Data.Channels, as: Store
  alias Data.Customers.Channel
  alias Data.Scope

  @fields Channel.fields() ++ [:customer_id, :handle_normalized, :archived_at]

  @doc "`GET /customers/:id/channels`, and the portal's `GET /channels` with the scope's own id."
  @spec list(Scope.t(), binary()) :: {:ok, [Channel.t()]} | {:error, term()}
  def list(%Scope{} = scope, customer_id) do
    with {:ok, customer} <- Customers.fetch(scope, :read, customer_id),
         :ok <- Access.why_not(scope, :read, {:channel, %{customer: customer}}),
         do: {:ok, with_forwarding(scope, Store.list(customer.id))}
  end

  @doc "`GET /channels/:id`."
  @spec get(Scope.t(), binary()) :: {:ok, Channel.t()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, channel} <- fetch(scope, :read, id), do: {:ok, forwarding(scope, channel)}
  end

  defp fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Channel{} = channel <- Store.get(id) || {:error, :not_found},
         true <- channel.customer.organisation_id == organisation.id || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:channel, channel}) do
      {:ok, channel}
    end
  end

  @doc "`POST /customers/:id/channels {kind, handle, label?, operated_by?, listens_via?}`."
  @spec create(Scope.t(), binary(), map(), DateTime.t()) :: {:ok, Channel.t()} | {:error, term()}
  def create(%Scope{} = scope, customer_id, params, %DateTime{} = now) do
    with {:ok, customer} <- Customers.fetch(scope, :read, customer_id),
         :ok <- Access.why_not(scope, :create, {:channel, %{customer: customer}}) do
      attrs = params |> take() |> Map.put("customer_id", customer.id)
      answer(scope, Customers.commit(fn -> insert(scope, attrs, now) end))
    end
  end

  defp insert(scope, attrs, now) do
    with {:ok, channel} <- Store.create(attrs) do
      {:ok, _event} = Audit.record(scope, "created", channel, after: snapshot(channel), now: now)
      {:ok, channel}
    end
  end

  @doc "`PATCH /channels/:id`."
  @spec update(Scope.t(), binary(), map()) :: {:ok, Channel.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    with {:ok, channel} <- fetch(scope, :update, id) do
      answer(scope, Customers.commit(fn -> write(scope, channel, take(params)) end))
    end
  end

  defp write(scope, channel, attrs) do
    with {:ok, updated} <- Store.update(channel, attrs) do
      {:ok, _event} =
        Audit.record(scope, "updated", updated,
          before: snapshot(channel),
          after: snapshot(updated)
        )

      {:ok, Store.reload(updated)}
    end
  end

  @doc "`POST /channels/:id/archive`: the handle is free for a new row afterwards."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Channel.t()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, channel} <- fetch(scope, :archive, id) do
      Customers.commit(fn ->
        {:ok, archived} = Store.archive(channel, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(channel),
            after: snapshot(archived),
            now: now
          )

        {:ok, Store.reload(archived)}
      end)
      |> then(&answer(scope, &1))
    end
  end

  @doc """
  `POST /channels/:id/inbound-address` (*New address*): a fresh token, the
  old address dead at once, audited. 422 on a channel that isn't email.
  """
  @spec renew_address(Scope.t(), binary(), DateTime.t()) :: {:ok, Channel.t()} | {:error, term()}
  def renew_address(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, channel} <- fetch(scope, :read, id),
         :ok <- email(channel),
         :ok <- Access.why_not(scope, :renew_address, {:channel, subject(channel)}) do
      answer(scope, Customers.commit(fn -> renewed(scope, channel, now) end))
    end
  end

  defp renewed(scope, channel, now) do
    with {:ok, renewed} <- Store.renew_token(channel) do
      {:ok, _event} =
        Audit.record(scope, "address_renewed", renewed,
          before: %{"inbound_token" => channel.inbound_token},
          after: %{"inbound_token" => renewed.inbound_token},
          now: now
        )

      {:ok, Store.reload(renewed)}
    end
  end

  defp email(%Channel{kind: :email}), do: :ok

  defp email(_channel),
    do: {:error, {:invalid, %{"kind" => ["Only an email channel has a forwarding address."]}}}

  # What `Core.Access.Channels` decides *New address* on.
  defp subject(channel) do
    owners =
      for %{profile: %{profile_members: members}} <- channel.profile_channels,
          is_list(members),
          m <- members,
          do: m.user_id

    Map.put(channel, :owner_user_ids, Enum.uniq(owners))
  end

  defp answer(scope, {:ok, %Channel{} = channel}), do: {:ok, forwarding(scope, channel)}
  defp answer(_scope, error), do: error

  defp with_forwarding(scope, channels) do
    checks =
      channels
      |> Enum.filter(&(&1.kind == :email))
      |> Enum.map(& &1.id)
      |> Data.Inbound.open_confirmations()

    Enum.map(channels, &forwarding(scope, &1, checks))
  end

  @doc false
  # The channel with its `forwarding` (AQ-09 §11.4) for `scope`.
  def forwarding(scope, channel, checks \\ nil)

  def forwarding(scope, %Channel{kind: :email} = channel, checks) do
    checks = checks || Data.Inbound.open_confirmations([channel.id])

    check =
      case Map.get(checks, channel.id) do
        nil -> nil
        c -> %{code: c.code, url: c.confirm_url, received_at: c.received_at}
      end

    %{
      channel
      | forwarding: %{
          address: Inbound.address(channel.inbound_token),
          last_inbound_at: channel.last_inbound_at,
          confirmation: check,
          can_renew: Access.can?(scope, :renew_address, {:channel, subject(channel)})
        }
    }
  end

  def forwarding(_scope, %Channel{} = channel, _checks), do: %{channel | forwarding: nil}

  defp take(params),
    do: params |> Customers.stringify() |> Map.take(Enum.map(Channel.fields(), &to_string/1))

  defp snapshot(channel), do: Audit.snapshot(channel, @fields)
end
