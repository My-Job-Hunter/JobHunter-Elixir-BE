defmodule Data.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  @moduledoc """
  A connected extension (AQ-05 §5.1, QP5-5): one row per browser that
  exchanged a connect code. Its tokens are a Guardian pair whose `sid` is
  this row's id and whose `dev.app` is `ext`; *Disconnect* deletes them and
  sets `revoked_at` (with who, nilified when that account goes). `name` is
  what a person recognises ("Chrome on macOS", `Core.Accounts.Device`).
  """

  def change do
    create table(:devices, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:name, :string, size: 80, null: false)
      add(:agent, :string, size: 300)
      add(:extension_version, :string, size: 20)
      add(:connected_at, :timestamptz, null: false)
      add(:last_seen_at, :timestamptz)
      add(:revoked_at, :timestamptz)
      add(:revoked_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:devices, :name_present, check: "btrim(name) <> ''"))

    create(
      constraint(:devices, :revoked_by_only_revoked,
        check: "revoked_by_user_id IS NULL OR revoked_at IS NOT NULL"
      )
    )

    # "This person's connected devices": Account › Extension.
    create(
      index(:devices, [:user_id],
        where: "revoked_at IS NULL",
        name: :devices_live_user_index
      )
    )

    create(index(:devices, [:organisation_id]))
    create(index(:devices, [:user_id]))
    create(index(:devices, [:revoked_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON devices " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON devices"
    )
  end
end
