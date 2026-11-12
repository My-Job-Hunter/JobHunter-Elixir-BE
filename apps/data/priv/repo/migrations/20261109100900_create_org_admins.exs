defmodule Data.Repo.Migrations.CreateOrgAdmins do
  use Ecto.Migration

  @moduledoc """
  The organisation's **one system admin** (AQ-01 §4.2; AQ-04A §4.0,
  QP4a-21): unique per organisation. No route grants or revokes it; the
  bootstrap's admin invitation makes the row, and `mix aq.admin --to
  <email>` hands it to another account, audited.
  """

  def change do
    create table(:org_admins, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:granted_at, :timestamptz, null: false)
      add(:granted_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
    end

    create(unique_index(:org_admins, [:organisation_id]))
    create(index(:org_admins, [:user_id]))
    create(index(:org_admins, [:granted_by_user_id]))
  end
end
