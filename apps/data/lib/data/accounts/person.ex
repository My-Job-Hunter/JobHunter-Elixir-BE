defmodule Data.Accounts.Person do
  @moduledoc """
  A human, with or without an account (AQ-01 §4.1). The name, the photo, the
  timezone and the locale live here, not on the login. The photo is a link
  row (`person_photos`), read through `photo_media_id/1`.
  """

  use Data.Schema

  alias Data.Accounts.PersonPhoto

  @type t :: %__MODULE__{}

  schema "persons" do
    field(:display_name, :string)
    field(:given_name, :string)
    field(:family_name, :string)
    field(:timezone, :string, default: "Asia/Karachi")
    field(:locale_code, :string, default: "en")

    has_one(:photo, PersonPhoto)

    timestamps()
  end

  @doc "The media id of the person's photo, or `nil` (also when the link is not loaded)."
  @spec photo_media_id(t()) :: binary() | nil
  def photo_media_id(%__MODULE__{photo: %PersonPhoto{media_id: id}}), do: id
  def photo_media_id(%__MODULE__{}), do: nil

  @doc "The name, the names, the zone and the language; the photo is `put_photo/2`'s."
  def changeset(person, attrs) do
    person
    |> cast(attrs, [:display_name, :given_name, :family_name, :timezone, :locale_code])
    |> update_change(:display_name, &(&1 && String.trim(&1)))
    |> validate_required([:display_name, :timezone, :locale_code])
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:given_name, max: 80)
    |> validate_length(:family_name, max: 80)
    |> validate_format(:locale_code, ~r/^[a-z]{2}(-[A-Z]{2})?$/, message: "is not a locale")
    |> validate_timezone()
    |> check_constraint(:display_name, name: :display_name_present)
  end

  # Checked against the configured time zone database rather than a regex:
  # "Europe/Karachi" is well-formed and does not exist.
  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        _unknown -> [timezone: "is not a known IANA timezone"]
      end
    end)
  end
end
