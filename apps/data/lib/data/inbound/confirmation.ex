defmodule Data.Inbound.Confirmation do
  @moduledoc """
  Gmail's forwarding check on an email channel (AQ-09 §8): the code and
  the link, until the first real mail clears it. One open per channel.
  """

  use Data.Schema

  alias Data.Customers.Channel

  @type t :: %__MODULE__{}

  schema "channel_confirmations" do
    field(:code, :string)
    field(:confirm_url, :string)
    field(:received_at, :utc_datetime_usec)
    field(:cleared_at, :utc_datetime_usec)

    belongs_to(:channel, Channel)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:channel_id, :code, :confirm_url, :received_at, :cleared_at])
    |> validate_required([:channel_id, :received_at])
    |> validate_length(:code, max: 40)
    |> validate_length(:confirm_url, max: 2000)
    |> check_constraint(:code, name: :code_or_url, message: "or a link is needed")
    |> unique_constraint(:channel_id, name: :channel_confirmations_open_index)
  end
end
