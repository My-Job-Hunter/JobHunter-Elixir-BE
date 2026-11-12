defmodule Data.Accounts.UserIdentity do
  @moduledoc """
  An account's link to an outside sign-in (AQ-01 §4.1): Google, keyed by its
  stable `sub`, never by the address.
  """

  use Data.Schema

  alias Data.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_identities" do
    field(:provider, Ecto.Enum, values: [:google])
    field(:provider_subject, :string)
    field(:email, :string)
    field(:linked_at, :utc_datetime_usec)

    belongs_to(:user, User)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider, :provider_subject, :email, :linked_at])
    |> validate_required([:user_id, :provider, :provider_subject, :linked_at])
    |> check_constraint(:provider, name: :provider_known)
    |> unique_constraint([:provider, :provider_subject])
    |> unique_constraint([:user_id, :provider])
    |> foreign_key_constraint(:user_id)
  end
end
