defmodule Data.Notifications.Delivery do
  @moduledoc """
  One notification's delivery on one channel beyond the bell (AQ-08 §5,
  QP8-2): when it may go, whether quiet hours hold it, and what became of
  it. Unique per notification and channel, so nothing goes twice.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Notifications.Notification
  alias Data.Organisations.Organisation

  @channels Data.Vocabulary.delivery_channels() |> Enum.map(&String.to_atom/1)
  @states Data.Vocabulary.delivery_states() |> Enum.map(&String.to_atom/1)
  @skip_reasons Data.Vocabulary.delivery_skip_reasons() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "notification_deliveries" do
    field(:channel, Ecto.Enum, values: @channels)
    field(:state, Ecto.Enum, values: @states, default: :pending)
    field(:deliver_after, :utc_datetime_usec)
    field(:deferred, :boolean, default: false)
    field(:skip_reason, Ecto.Enum, values: @skip_reasons)
    field(:error, :string)
    field(:attempts, :integer, default: 0)
    field(:sent_at, :utc_datetime_usec)
    field(:ics, :string)

    belongs_to(:organisation, Organisation)
    belongs_to(:notification, Notification)
    belongs_to(:user, User)

    timestamps()
  end

  @doc "The ledger's channels, in vocabulary order."
  def channels, do: @channels
end
