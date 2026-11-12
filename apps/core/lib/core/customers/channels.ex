defmodule Core.Customers.Channels do
  @moduledoc """
  A customer's channels (AQ-01 §4.3, §6.2, §6.3): the accounts the team
  works through. Every staff role of a serving team has full run of them,
  and so does the customer (§5.3). **Nothing here stores a credential**
  (PLAN Q3): `operated_by` says who holds the login.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Data.Channels, as: Store
  alias Data.Customers.Channel
  alias Data.Scope

  @fields Channel.fields() ++ [:customer_id, :handle_normalized, :archived_at]

  @doc "`GET /customers/:id/channels`, and the portal's `GET /channels` with the scope's own id."
  @spec list(Scope.t(), binary()) :: {:ok, [Channel.t()]} | {:error, term()}
  def list(%Scope{} = scope, customer_id) do
    with {:ok, customer} <- Customers.fetch(scope, :read, customer_id),
         :ok <- Access.why_not(scope, :read, {:channel, %{customer: customer}}),
         do: {:ok, Store.list(customer.id)}
  end

  @doc "`GET /channels/:id`."
  @spec get(Scope.t(), binary()) :: {:ok, Channel.t()} | {:error, term()}
  def get(%Scope{} = scope, id), do: fetch(scope, :read, id)

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
      Customers.commit(fn -> insert(scope, attrs, now) end)
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
      Customers.commit(fn -> write(scope, channel, take(params)) end)
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
    end
  end

  defp take(params),
    do: params |> Customers.stringify() |> Map.take(Enum.map(Channel.fields(), &to_string/1))

  defp snapshot(channel), do: Audit.snapshot(channel, @fields)
end
