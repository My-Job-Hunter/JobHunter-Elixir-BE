defmodule Data.Channels do
  @moduledoc """
  A customer's channels (AQ-01 §4.3). Storage only. Every read answers the
  channel with its customer (and the customer's `team_ids`), because
  `Core.Access` decides from the customer.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Customers.Channel
  alias Data.Repo

  @preload [profile_channels: [profile: :profile_members], customer: [:customer_teams]]

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

  @doc """
  The organisation's live channel whose account is `key` (`Utils.ChannelKey`),
  with its customer and its profile links, or `nil` (AQ-05 §8).
  """
  @spec by_identity(binary(), String.t() | nil) :: Channel.t() | nil
  def by_identity(_organisation_id, nil), do: nil

  def by_identity(organisation_id, key) when is_binary(key) do
    from(c in Channel,
      join: cu in assoc(c, :customer),
      where:
        cu.organisation_id == ^organisation_id and c.identity_key == ^key and
          is_nil(c.archived_at),
      preload: ^@preload
    )
    |> Repo.one()
    |> fill()
  end

  @doc "Moves `last_seen_at`: the extension saw the account signed in (AQ-05 §8)."
  @spec seen(Channel.t(), DateTime.t()) :: :ok
  def seen(%Channel{id: id}, %DateTime{} = at) do
    {_n, _rows} = Repo.update_all(from(c in Channel, where: c.id == ^id), set: [last_seen_at: at])
    :ok
  end

  @doc """
  The live email channel whose token is `token` (AQ-09 §6.1), with its
  customer, its profiles and their owners, or `nil`: an archived channel's
  address is nobody's.
  """
  @spec by_token(String.t() | nil) :: Channel.t() | nil
  def by_token(nil), do: nil

  def by_token(token) when is_binary(token) do
    from(c in Channel,
      where:
        c.inbound_token == ^String.downcase(token) and c.kind == :email and
          is_nil(c.archived_at),
      preload: ^@preload
    )
    |> Repo.one()
    |> fill()
  end

  @doc "*New address* (AQ-09 QP9-6): a fresh token; the old one stops at once."
  @spec renew_token(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def renew_token(%Channel{kind: :email} = channel) do
    channel
    |> Ecto.Changeset.change(inbound_token: Channel.new_token())
    |> Ecto.Changeset.unique_constraint(:inbound_token, name: :channels_inbound_token_index)
    |> Repo.update()
  end

  @doc "Moves `last_inbound_at` forward to `at`: a mail landed through the address."
  @spec mark_inbound(binary(), DateTime.t()) :: :ok
  def mark_inbound(channel_id, %DateTime{} = at) do
    {_n, _rows} =
      from(c in Channel,
        where: c.id == ^channel_id and (is_nil(c.last_inbound_at) or c.last_inbound_at < ^at)
      )
      |> Repo.update_all(set: [last_inbound_at: at])

    :ok
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
