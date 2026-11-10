defmodule Data.Repo.Migrations.CreateOrgAdmins do
  use Ecto.Migration

  @moduledoc """
  Who administers the organisation (JH-01 §4.2). One row per admin; the last
  admin cannot be removed (a guard in `Core.Organisation`, tested).
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

    create(unique_index(:org_admins, [:organisation_id, :user_id]))
    create(index(:org_admins, [:user_id]))
    create(index(:org_admins, [:granted_by_user_id]))
  end
end
