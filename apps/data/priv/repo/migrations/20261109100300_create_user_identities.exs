defmodule Data.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  @moduledoc """
  An account's link to an outside sign-in: Google (JH-01 §4.1, QP1-5).

  Keyed by Google's own stable `sub`, never by the address, which a person
  can change at Google. One account per identity, one identity per provider
  per account.
  """

  def change do
    create table(:user_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:provider, :string, null: false)
      add(:provider_subject, :string, null: false)
      add(:email, :citext)
      add(:linked_at, :timestamptz, null: false)
    end

    create(constraint(:user_identities, :provider_known, check: "provider IN ('google')"))
    create(unique_index(:user_identities, [:provider, :provider_subject]))
    create(unique_index(:user_identities, [:user_id, :provider]))
  end
end
