defmodule Data.Organisations.Organisation do
  @moduledoc """
  The organisation (AQ-01 §4.2): one today, every business row carries its id.
  """

  use Data.Schema

  @type t :: %__MODULE__{}

  schema "organisations" do
    field(:name, :string)
    field(:slug, :string)
    field(:country_code, :string)
    field(:timezone, :string, default: "Asia/Karachi")
    field(:currency_code, :string, default: "USD")

    timestamps()
  end

  def changeset(organisation, attrs) do
    organisation
    |> cast(attrs, [:name, :slug, :country_code, :timezone, :currency_code])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> put_slug()
    |> validate_required([:name, :slug, :timezone, :currency_code])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, message: "is not a slug")
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/, message: "is not an ISO country code")
    |> validate_format(:currency_code, ~r/^[A-Z]{3}$/, message: "is not an ISO currency code")
    |> validate_timezone()
    |> check_constraint(:name, name: :name_present)
    |> unique_constraint(:slug)
  end

  # The slug follows the name unless one was given.
  defp put_slug(changeset) do
    case {get_change(changeset, :slug), get_change(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
      _given_or_unchanged -> changeset
    end
  end

  @doc "A URL-safe slug from a name: lower, ASCII, hyphens."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        _unknown -> [timezone: "is not a known IANA timezone"]
      end
    end)
  end
end
