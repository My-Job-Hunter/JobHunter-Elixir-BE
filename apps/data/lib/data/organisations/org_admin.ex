defmodule Data.Organisations.OrgAdmin do
  @moduledoc "One admin of the organisation (JH-01 §4.2)."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "org_admins" do
    field(:granted_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)
    belongs_to(:granted_by_user, User)
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:organisation_id, :user_id, :granted_at, :granted_by_user_id])
    |> validate_required([:organisation_id, :user_id, :granted_at])
    |> unique_constraint([:organisation_id, :user_id], message: "is already an admin")
    |> foreign_key_constraint(:organisation_id)
    |> foreign_key_constraint(:user_id)
  end
end
