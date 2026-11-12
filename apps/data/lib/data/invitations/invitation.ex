defmodule Data.Invitations.Invitation do
  @moduledoc """
  One invitation (AQ-01 §3, §4.2): what the person becomes, for whom, until
  when. `state/2` reads it as the screen does: open, accepted, expired,
  revoked.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Customer
  alias Data.Organisations.Organisation
  alias Data.Teams.Team

  @kinds ~w(admin team_member customer)a
  @roles Data.Vocabulary.team_member_roles() |> Enum.map(&String.to_atom/1)
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_shape ~r/^[A-HJ-NP-Z2-9]{2}-[A-HJ-NP-Z2-9]{4}$/

  @type t :: %__MODULE__{}
  @type state :: :open | :accepted | :expired | :revoked

  schema "invitations" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:code, :string)
    field(:email, :string)
    field(:invited_name, :string)
    field(:role, Ecto.Enum, values: @roles)
    field(:expires_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:customer, Customer)
    belongs_to(:invited_by_user, User)
    belongs_to(:accepted_by_user, User)

    timestamps()
  end

  def kinds, do: @kinds
  def code_shape, do: @code_shape

  @doc "A fresh `XX-XXXX` code from the unambiguous alphabet."
  @spec generate_code() :: String.t()
  def generate_code do
    [a, b, c, d, e, f] = for _n <- 1..6, do: Enum.random(@alphabet)
    <<a, b, ?-, c, d, e, f>>
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :organisation_id,
      :kind,
      :code,
      :email,
      :invited_name,
      :team_id,
      :role,
      :customer_id,
      :invited_by_user_id,
      :expires_at
    ])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:invited_name, &(&1 && String.trim(&1)))
    |> validate_required([:organisation_id, :kind, :code, :email, :expires_at])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "is not a valid email")
    |> validate_length(:invited_name, max: 120)
    |> validate_format(:code, @code_shape)
    |> validate_kind_fields()
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:role, name: :role_known)
    |> check_constraint(:code, name: :code_shape)
    |> check_constraint(:kind, name: :kind_fields_match)
    |> unique_constraint(:code)
    |> unique_constraint([:organisation_id, :email],
      name: :invitations_one_open_admin_index,
      error_key: :email,
      message: "already has an open invitation"
    )
    |> unique_constraint([:email, :team_id],
      name: :invitations_one_open_team_member_index,
      error_key: :email,
      message: "already has an open invitation to this team"
    )
    |> unique_constraint([:email, :customer_id],
      name: :invitations_one_open_customer_index,
      error_key: :email,
      message: "already has an open invitation"
    )
    |> foreign_key_constraint(:organisation_id)
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:customer_id)
  end

  defp validate_kind_fields(changeset) do
    has = fn field -> not is_nil(get_field(changeset, field)) end

    case get_field(changeset, :kind) do
      :team_member ->
        changeset
        |> validate_required([:team_id, :role])
        |> refuse_if(has.(:customer_id), :customer_id, "is only for a customer invitation")

      :customer ->
        changeset
        |> validate_required([:customer_id])
        |> refuse_if(has.(:team_id) or has.(:role), :team_id, "is only for a team invitation")

      :admin ->
        refuse_if(
          changeset,
          has.(:team_id) or has.(:role) or has.(:customer_id),
          :kind,
          "an admin invitation names no team or customer"
        )

      nil ->
        changeset
    end
  end

  defp refuse_if(changeset, true, field, message), do: add_error(changeset, field, message)
  defp refuse_if(changeset, false, _field, _message), do: changeset

  @doc "What the row is at `now`: open, accepted, expired or revoked."
  @spec state(t(), DateTime.t()) :: state()
  def state(%__MODULE__{} = invitation, %DateTime{} = now) do
    cond do
      invitation.revoked_at -> :revoked
      invitation.accepted_at -> :accepted
      DateTime.compare(invitation.expires_at, now) != :gt -> :expired
      true -> :open
    end
  end
end
