defmodule Data.Inbound do
  @moduledoc """
  The intake's storage (AQ-09 §5): the log of deliveries
  (`inbound_messages`) and Gmail's forwarding checks
  (`channel_confirmations`). Storage only: what a delivery becomes is
  `Core.Inbound`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Inbound.{Confirmation, InboundMessage}
  alias Data.Repo

  # ── The log ─────────────────────────────────────────────────────────────────

  @doc "The delivery a provider already made with this id, or `nil` (its retry)."
  @spec delivery(atom(), String.t() | nil) :: InboundMessage.t() | nil
  def delivery(_provider, nil), do: nil

  def delivery(provider, provider_message_id),
    do: Repo.get_by(InboundMessage, provider: provider, provider_message_id: provider_message_id)

  @doc """
  A delivery logged. The same `(provider, provider_message_id)` twice adds
  nothing (a retry racing the first): answers `{:ok, :kept}` then.
  """
  @spec log(map()) :: {:ok, InboundMessage.t() | :kept} | {:error, Ecto.Changeset.t()}
  def log(attrs) do
    case %InboundMessage{} |> InboundMessage.changeset(attrs) |> Repo.insert() do
      {:ok, row} ->
        {:ok, row}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :provider_message_id),
          do: {:ok, :kept},
          else: {:error, changeset}
    end
  end

  @doc "A channel's deliveries, newest first (at most `limit`)."
  @spec for_channel(binary(), pos_integer()) :: [InboundMessage.t()]
  def for_channel(channel_id, limit \\ 50) do
    from(i in InboundMessage,
      where: i.channel_id == ^channel_id,
      order_by: [desc: i.received_at, desc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Deletes the log's rows received before `before` (QP9-8: 30 days). Answers how many."
  @spec sweep_for_system(DateTime.t()) :: non_neg_integer()
  def sweep_for_system(%DateTime{} = before) do
    {count, _rows} = Repo.delete_all(from(i in InboundMessage, where: i.received_at < ^before))
    count
  end

  # ── Gmail's forwarding check ────────────────────────────────────────────────

  @doc "The channel's open check, or `nil`."
  @spec open_confirmation(binary()) :: Confirmation.t() | nil
  def open_confirmation(channel_id) do
    from(c in Confirmation, where: c.channel_id == ^channel_id and is_nil(c.cleared_at))
    |> Repo.one()
  end

  @doc "The open checks of `channel_ids`: `%{channel_id => confirmation}`."
  @spec open_confirmations([binary()]) :: %{binary() => Confirmation.t()}
  def open_confirmations([]), do: %{}

  def open_confirmations(channel_ids) do
    from(c in Confirmation, where: c.channel_id in ^channel_ids and is_nil(c.cleared_at))
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  @doc "A new check on the channel: an open one is cleared first (one open per channel)."
  @spec put_confirmation(binary(), map()) ::
          {:ok, Confirmation.t()} | {:error, Ecto.Changeset.t()}
  def put_confirmation(channel_id, %{received_at: at} = attrs) do
    :ok = clear_confirmations(channel_id, at)

    %Confirmation{}
    |> Confirmation.changeset(Map.put(attrs, :channel_id, channel_id))
    |> Repo.insert()
  end

  @doc "Clears the channel's open check (the first real mail arrived)."
  @spec clear_confirmations(binary(), DateTime.t()) :: :ok
  def clear_confirmations(channel_id, %DateTime{} = at) do
    {_n, _rows} =
      from(c in Confirmation, where: c.channel_id == ^channel_id and is_nil(c.cleared_at))
      |> Repo.update_all(set: [cleared_at: at])

    :ok
  end
end
