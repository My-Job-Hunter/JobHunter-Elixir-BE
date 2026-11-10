defmodule Data.Channels do
  @moduledoc """
  A customer's channels (JH-01 §4.3). Storage only. Every read answers the
  channel with its customer (and the customer's `team_ids`), because
  `Core.Access` decides from the customer.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Customers.Channel
  alias Data.Repo

  @preload [:profile_channels, customer: [:customer_teams]]

  @spec get(binary()) :: Channel.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Channel |> Repo.get(uuid) |> Repo.preload(@preload) |> fill()
      :error -> nil
    end
  end

  def get(_id), do: nil

  @doc "A customer's live channels, by kind then handle."
  @spec list(binary(), keyword()) :: [Channel.t()]
  def list(customer_id, opts \\ []) do
    query =
      from(c in Channel,
        where: c.customer_id == ^customer_id,
        order_by: [asc: c.kind, asc: c.handle_normalized],
        preload: ^@preload
      )

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [c], is_nil(c.archived_at))

    query |> Repo.all() |> Enum.map(&fill/1)
  end

  @doc "The live channels of a customer among `ids`: what a profile may be linked to."
  @spec live_ids(binary(), [binary()]) :: [binary()]
  def live_ids(_customer_id, []), do: []

  def live_ids(customer_id, ids) do
    from(c in Channel,
      where: c.customer_id == ^customer_id and c.id in ^ids and is_nil(c.archived_at),
      select: c.id
    )
    |> Repo.all()
  end

  @spec reload(Channel.t()) :: Channel.t()
  def reload(%Channel{id: id}), do: get(id)

  defp fill(nil), do: nil
  defp fill(%Channel{} = channel), do: %{channel | customer: Customers.fill(channel.customer)}

  @spec create(map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, channel} <- %Channel{} |> Channel.changeset(attrs) |> Repo.insert() do
      {:ok, reload(channel)}
    end
  end

  @spec update(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update(%Channel{} = channel, attrs),
    do: channel |> Channel.changeset(attrs) |> Repo.update()

  @spec archive(Channel.t(), DateTime.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Channel{} = channel, %DateTime{} = at),
    do: channel |> Ecto.Changeset.change(archived_at: at) |> Repo.update()
end
