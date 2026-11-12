defmodule Data.Contacts.Handle do
  @moduledoc """
  A contact's way in (AQ-06 §5.1, QP6-3): `value` as typed,
  `value_normalized` made here (`normalize/2`) so no caller can forget it
  and two spellings of one account meet the unique `(organisation, kind,
  value_normalized)`:

  | Kind | Normalised |
  |---|---|
  | `email` | trimmed, lowercased; it must hold an `@` |
  | `linkedin` | P5's `Utils.ChannelKey` (`linkedin:mei-chen-example`); a link it can't read is a field error |
  | `upwork` | `Utils.ChannelKey` (`upwork:~01…`) for a freelancer link; else as typed, lowercased (a client named in a room) |
  | `phone` | its digits, at least six |
  | `other` | trimmed, lowercased |
  """

  use Data.Schema

  alias Data.Contacts.Contact
  alias Data.Organisations.Organisation
  alias Data.Vocabulary
  alias Utils.ChannelKey

  @kinds Vocabulary.contact_handle_kinds() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "contact_handles" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:value, :string)
    field(:value_normalized, :string)
    field(:is_invalid, :boolean, default: false)

    belongs_to(:organisation, Organisation)
    belongs_to(:contact, Contact)

    timestamps()
  end

  @doc """
  A handle's normalised value, or `{:error, message}` for one that cannot
  be an account of its kind. Pure.

      iex> Data.Contacts.Handle.normalize(:email, " Mei.Chen@JuniperEdge.example ")
      {:ok, "mei.chen@juniperedge.example"}
      iex> Data.Contacts.Handle.normalize(:linkedin, "linkedin.com/in/Mei-Chen-Example/?trk=x")
      {:ok, "linkedin:mei-chen-example"}
      iex> Data.Contacts.Handle.normalize(:phone, "+92 (300) 123-4567")
      {:ok, "923001234567"}
  """
  @spec normalize(atom() | String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(kind, value) when is_binary(kind) do
    if kind in Vocabulary.contact_handle_kinds(),
      do: normalize(String.to_existing_atom(kind), value),
      else: {:error, "is not a kind of handle"}
  end

  def normalize(_kind, value) when not is_binary(value), do: {:error, "can't be blank"}

  def normalize(kind, value) do
    case String.trim(value) do
      "" -> {:error, "can't be blank"}
      trimmed -> by_kind(kind, trimmed)
    end
  end

  defp by_kind(:email, value) do
    if value =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      do: {:ok, String.downcase(value)},
      else: {:error, "is not an email address"}
  end

  defp by_kind(:linkedin, value) do
    case ChannelKey.key(:linkedin, value) do
      nil -> {:error, "is not a LinkedIn profile link"}
      key -> {:ok, key}
    end
  end

  defp by_kind(:upwork, value) do
    case ChannelKey.key(:upwork, value) do
      nil -> {:ok, String.downcase(value)}
      key -> {:ok, key}
    end
  end

  defp by_kind(:phone, value) do
    digits = String.replace(value, ~r/\D/, "")
    if String.length(digits) >= 6, do: {:ok, digits}, else: {:error, "is not a phone number"}
  end

  defp by_kind(:other, value), do: {:ok, String.downcase(value)}
  defp by_kind(_kind, _value), do: {:error, "is not a kind of handle"}

  def changeset(handle, attrs) do
    handle
    |> cast(attrs, [:organisation_id, :contact_id, :kind, :value, :is_invalid])
    |> update_change(:value, &(&1 && String.trim(&1)))
    |> validate_required([:organisation_id, :contact_id, :kind, :value])
    |> validate_length(:value, max: 300)
    |> put_normalized()
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:value, name: :value_present, message: "can't be blank")
    |> unique_constraint([:organisation_id, :kind, :value_normalized],
      name: :contact_handles_organisation_id_kind_value_normalized_index,
      error_key: :value,
      message: "is another contact's already"
    )
    |> foreign_key_constraint(:contact_id)
  end

  @doc "Moved to another contact (a merge), or marked invalid (a bounce)."
  def move_changeset(handle, attrs), do: cast(handle, attrs, [:contact_id, :is_invalid])

  defp put_normalized(%Ecto.Changeset{valid?: true} = changeset) do
    kind = get_field(changeset, :kind)
    value = get_field(changeset, :value)

    case normalize(kind, value) do
      {:ok, normalized} -> put_change(changeset, :value_normalized, normalized)
      {:error, message} -> add_error(changeset, :value, message)
    end
  end

  defp put_normalized(changeset), do: changeset
end
