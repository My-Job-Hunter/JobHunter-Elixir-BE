defmodule Data.Customers.Customer do
  @moduledoc """
  A person the team hunts for (JH-01 §4.3). A business row first, a login
  second: `user_id` is nil until the portal invitation is accepted. `status`
  changes are audited by `Core.Customers`.

  `team_ids` is virtual, filled by `Data.Customers` from `customer_teams` on
  every read, because `Core.Access` decides visibility from it (a customer
  in no team is an admin's or a manager's, QP1-8) and a decision should not
  depend on which association happens to be loaded.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.{Channel, CustomerNote, CustomerTeam, Profile}
  alias Data.Organisations.Organisation

  @statuses Data.Vocabulary.customer_statuses() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "customers" do
    field(:display_name, :string)
    field(:email, :string)
    field(:phone_e164, :string)
    field(:timezone, :string, default: "Asia/Karachi")
    field(:location_text, :string)
    field(:country_code, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :invited)
    field(:started_on, :date)
    field(:ended_on, :date)
    field(:archived_at, :utc_datetime_usec)
    field(:team_ids, {:array, :binary_id}, virtual: true, default: [])

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)
    has_many(:customer_teams, CustomerTeam)
    has_many(:teams, through: [:customer_teams, :team])
    has_many(:profiles, Profile)
    has_many(:channels, Channel)
    has_many(:notes, CustomerNote)

    timestamps()
  end

  @doc "The statuses, as atoms."
  def statuses, do: @statuses

  @doc "The fields staff set at creation and edit later; the portal edits `portal_fields/0`."
  def staff_fields,
    do: ~w(display_name email phone_e164 timezone location_text country_code started_on ended_on)a

  @doc "What a customer changes about themselves (§6.3): phone, timezone, location."
  def portal_fields, do: ~w(phone_e164 timezone location_text country_code)a

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:organisation_id | staff_fields()])
    |> update_change(:display_name, &(&1 && String.trim(&1)))
    |> update_change(:email, &(&1 && &1 |> String.trim() |> String.downcase()))
    |> validate_required([:organisation_id, :display_name, :email, :timezone])
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "is not a valid email")
    |> validate_format(:phone_e164, ~r/^\+[1-9]\d{6,14}$/, message: "is not an E.164 number")
    |> validate_format(:country_code, ~r/^[A-Z]{2}$/, message: "is not an ISO country code")
    |> validate_length(:location_text, max: 160)
    |> validate_timezone()
    |> check_constraint(:display_name, name: :display_name_present)
    |> check_constraint(:status, name: :status_known)
    |> unique_constraint([:organisation_id, :email],
      error_key: :email,
      message: "already belongs to a customer"
    )
    |> foreign_key_constraint(:organisation_id)
  end

  @doc "The verb's changeset: a new status, with the dates it implies."
  def status_changeset(customer, status, %Date{} = today) do
    customer
    |> change(status: status)
    |> put_dates(status, today)
    |> check_constraint(:status, name: :status_known)
  end

  defp put_dates(changeset, :active, today) do
    if get_field(changeset, :started_on),
      do: put_change(changeset, :ended_on, nil),
      else: changeset |> put_change(:started_on, today) |> put_change(:ended_on, nil)
  end

  defp put_dates(changeset, :ended, today), do: put_change(changeset, :ended_on, today)
  defp put_dates(changeset, _other, _today), do: changeset

  @doc "The accepted invitation: the login this customer signs in as."
  def login_changeset(customer, user_id) do
    customer
    |> change(user_id: user_id)
    |> unique_constraint(:user_id, message: "is already a customer")
    |> foreign_key_constraint(:user_id)
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
