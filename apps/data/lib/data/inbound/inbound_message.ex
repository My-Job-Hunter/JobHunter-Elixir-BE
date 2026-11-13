defmodule Data.Inbound.InboundMessage do
  @moduledoc """
  One delivery the intake accepted (AQ-09 §5, QP9-8): who delivered it,
  to which address, what became of it. No body.
  """

  use Data.Schema

  alias Data.Conversations.Message
  alias Data.Customers.Channel
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @providers Vocabulary.inbound_providers() |> Enum.map(&String.to_atom/1)
  @outcomes Vocabulary.inbound_outcomes() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "inbound_messages" do
    field(:provider, Ecto.Enum, values: @providers)
    field(:provider_message_id, :string)
    field(:rfc_message_id, :string)
    field(:to_address, :string)
    field(:outcome, Ecto.Enum, values: @outcomes)
    field(:bytes, :integer, default: 0)
    field(:received_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:channel, Channel)
    belongs_to(:message, Message)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :organisation_id,
      :channel_id,
      :provider,
      :provider_message_id,
      :rfc_message_id,
      :to_address,
      :outcome,
      :message_id,
      :bytes,
      :received_at
    ])
    |> update_change(:to_address, &(&1 && String.slice(&1, 0, 320)))
    |> update_change(:rfc_message_id, &(&1 && String.slice(&1, 0, 998)))
    |> validate_required([:provider, :outcome, :received_at])
    |> check_constraint(:provider, name: :provider_known)
    |> check_constraint(:outcome, name: :outcome_known)
    |> unique_constraint(:provider_message_id, name: :inbound_messages_delivery_index)
  end
end
