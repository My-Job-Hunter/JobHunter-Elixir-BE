defmodule Data.Companies.Company do
  @moduledoc """
  A company jobs belong to (AQ-03 §5.1, QP3-6). One per name in an
  organisation: `name_normalized` is made here from `name` (`normalize/1`:
  lower, unaccented, trimmed, inner spaces collapsed), so "Bamboo Invest" and
  " bamboo  invest" meet the unique index. The domain is unique too, when
  there is one.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @size_bands Vocabulary.company_size_bands() |> Enum.map(&String.to_atom/1)
  @fields ~w(name domain website_url linkedin_url size_band industry hq_country notes_md)a

  @type t :: %__MODULE__{}

  schema "companies" do
    field(:name, :string)
    field(:name_normalized, :string)
    field(:domain, :string)
    field(:website_url, :string)
    field(:linkedin_url, :string)
    field(:size_band, Ecto.Enum, values: @size_bands)
    field(:industry, :string)
    field(:hq_country, :string)
    field(:notes_md, :string)

    belongs_to(:organisation, Organisation)
    belongs_to(:created_by_user, User)

    timestamps()
  end

  @doc "What a person sets on a company."
  def fields, do: @fields

  @doc ~S|"  Café  Ñandú " → "cafe nandu": the form the unique index holds.|
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:organisation_id, :created_by_user_id | @fields])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> update_change(:domain, &domain/1)
    |> update_change(:hq_country, &(&1 && String.upcase(String.trim(&1))))
    |> put_normalized()
    |> validate_required([:organisation_id, :name, :name_normalized])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:industry, max: 120)
    |> validate_length(:notes_md, max: 20_000)
    |> validate_format(:hq_country, ~r/^[A-Z]{2}$/, message: "is not an ISO country code")
    |> validate_format(:domain, ~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/, message: "is not a domain")
    |> validate_link(:website_url)
    |> validate_link(:linkedin_url)
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> check_constraint(:size_band, name: :size_band_known)
    |> check_constraint(:hq_country, name: :hq_country_iso)
    |> unique_constraint([:organisation_id, :name_normalized],
      error_key: :name,
      message: "is already a company"
    )
    |> unique_constraint([:organisation_id, :domain],
      name: :companies_organisation_id_domain_index,
      error_key: :domain,
      message: "is already a company's"
    )
    |> foreign_key_constraint(:organisation_id)
  end

  defp put_normalized(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :name_normalized, normalize(name))
    end
  end

  # "https://www.Acme.io/careers" and "acme.io" are one domain.
  defp domain(nil), do: nil

  defp domain(value) do
    value = value |> String.trim() |> String.downcase()

    host =
      case URI.parse(if value =~ "://", do: value, else: "https://" <> value) do
        %URI{host: host} when is_binary(host) -> host
        _other -> value
      end

    case String.replace_prefix(host, "www.", "") do
      "" -> nil
      host -> host
    end
  end

  defp validate_link(changeset, field) do
    validate_change(changeset, field, fn ^field, url ->
      if Utils.SafeUrl.safe?(url), do: [], else: [{field, "is not a web link"}]
    end)
  end
end
