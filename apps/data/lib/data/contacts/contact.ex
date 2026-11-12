defmodule Data.Contacts.Contact do
  @moduledoc """
  A person on the other side (AQ-06 §5.1): a recruiter, a hiring manager,
  an interviewer, a client. The organisation's, not a team's (QP6-2).
  `name_normalized` is made here from `name` (`normalize/1`, as P3's
  company name is), so the match check's *possible* answer compares one
  form. A merged contact keeps its row with `merged_into_contact_id`.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Companies.Company
  alias Data.Contacts.Handle
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @sources Vocabulary.contact_sources() |> Enum.map(&String.to_atom/1)
  @fields ~w(name title company_id time_zone location notes_md)a

  @type t :: %__MODULE__{}

  schema "contacts" do
    field(:name, :string)
    field(:name_normalized, :string)
    field(:title, :string)
    field(:time_zone, :string)
    field(:location, :string)
    field(:source, Ecto.Enum, values: @sources, default: :manual)
    field(:is_do_not_contact, :boolean, default: false)
    field(:notes_md, :string)
    # Filled by `Data.Contacts`: how many leads it is on.
    field(:leads_count, :integer, virtual: true, default: 0)

    belongs_to(:organisation, Organisation)
    belongs_to(:company, Company)
    belongs_to(:merged_into_contact, __MODULE__)
    belongs_to(:created_by_user, User)
    has_many(:handles, Handle)

    timestamps()
  end

  @doc "What a person sets on a contact."
  def fields, do: @fields

  @doc ~S|"  Mei   Chen " → "mei chen": lower, unaccented, spaces collapsed.|
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

  @doc "A new contact: the organisation, who added it, where it came from, and its fields."
  def create_changeset(contact, attrs) do
    contact
    |> cast(attrs, [:organisation_id, :created_by_user_id, :source | @fields])
    |> validate_required([:organisation_id])
    |> common()
  end

  @doc "An edit: the fields a person sets, and `is_do_not_contact` (an unsubscribe)."
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:is_do_not_contact | @fields])
    |> common()
  end

  @doc "Merged into another contact (QP6-4)."
  def merged_changeset(contact, into_id),
    do: change(contact, merged_into_contact_id: into_id)

  defp common(changeset) do
    changeset
    |> update_change(:name, &trim/1)
    |> update_change(:title, &trim/1)
    |> update_change(:location, &trim/1)
    |> update_change(:time_zone, &trim/1)
    |> put_normalized()
    |> validate_required([:name, :name_normalized])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:title, max: 200)
    |> validate_length(:location, max: 200)
    |> validate_length(:notes_md, max: 20_000)
    |> validate_zone()
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> check_constraint(:source, name: :source_known)
    |> foreign_key_constraint(:company_id)
  end

  defp put_normalized(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :name_normalized, normalize(name))
    end
  end

  defp validate_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        _unknown -> [time_zone: "is not a known IANA time zone"]
      end
    end)
  end

  defp trim(nil), do: nil

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value
end
