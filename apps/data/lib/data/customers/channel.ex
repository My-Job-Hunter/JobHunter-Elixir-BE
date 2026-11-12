defmodule Data.Customers.Channel do
  @moduledoc """
  A customer's platform account (AQ-01 §4.3): the LinkedIn, the Upwork,
  the inbox. **No credential field exists** (PLAN Q3); `operated_by` says
  who holds the login. `handle_normalized` is derived from `handle` here so
  no caller can forget it, and so is `identity_key` (AQ-05 §8,
  `Utils.ChannelKey`): the account itself, one per kind among live
  channels, so one account belongs to one person.
  """

  use Data.Schema

  alias Data.Customers.{Customer, ProfileChannel}
  alias Data.Vocabulary

  @kinds Vocabulary.platforms() |> Enum.map(&String.to_atom/1)
  @operators Vocabulary.channel_operators() |> Enum.map(&String.to_atom/1)
  @listeners Vocabulary.channel_listeners() |> Enum.map(&String.to_atom/1)
  @statuses Vocabulary.channel_statuses() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "channels" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:label, :string)
    field(:handle, :string)
    field(:handle_normalized, :string)
    field(:identity_key, :string)
    field(:operated_by, Ecto.Enum, values: @operators, default: :customer)
    field(:listens_via, Ecto.Enum, values: @listeners, default: :none)
    field(:inbound_address, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: @statuses, default: :active)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:customer, Customer)
    has_many(:profile_channels, ProfileChannel)

    timestamps()
  end

  @doc "What a screen sets."
  def fields, do: ~w(kind label handle operated_by listens_via status)a

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:customer_id | fields()])
    |> update_change(:handle, &(&1 && String.trim(&1)))
    |> update_change(:label, &(&1 && String.trim(&1)))
    |> put_normalized()
    |> put_identity()
    |> validate_required([:customer_id, :kind, :handle, :handle_normalized, :operated_by])
    |> validate_length(:handle, min: 1, max: 300)
    |> validate_length(:label, max: 80)
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:operated_by, name: :operated_by_known)
    |> check_constraint(:listens_via, name: :listens_via_known)
    |> check_constraint(:status, name: :status_known)
    |> check_constraint(:handle, name: :handle_present)
    |> unique_constraint([:customer_id, :kind, :handle_normalized],
      name: :channels_live_handle_index,
      error_key: :handle,
      message: "is already one of this customer's channels"
    )
    |> unique_constraint([:kind, :identity_key],
      name: :channels_live_identity_index,
      error_key: :handle,
      message: "is already a channel of a customer: one account belongs to one person"
    )
    |> foreign_key_constraint(:customer_id)
  end

  # The key follows the handle and the kind, whichever of them changed.
  defp put_identity(changeset) do
    if changed?(changeset, :handle) or changed?(changeset, :kind) do
      key = Utils.ChannelKey.key(get_field(changeset, :kind), get_field(changeset, :handle))
      put_change(changeset, :identity_key, key)
    else
      changeset
    end
  end

  defp put_normalized(changeset) do
    case get_change(changeset, :handle) do
      nil -> changeset
      handle -> put_change(changeset, :handle_normalized, normalize(handle))
    end
  end

  @doc "Lower, trimmed, no trailing slash: what the unique is on."
  @spec normalize(String.t()) :: String.t()
  def normalize(handle),
    do: handle |> String.trim() |> String.downcase() |> String.trim_trailing("/")
end
