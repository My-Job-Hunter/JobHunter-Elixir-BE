defmodule Data.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  @moduledoc """
  A customer's platform accounts (JH-01 §4.3): the LinkedIn, the Upwork,
  the inbox the team works through. A channel belongs to the customer and
  is linked to the profiles that work through it (`profile_channels`).

  **No credential column exists** (PLAN Q3): who operates the account is
  `operated_by`; a staff login is a risk the screen names, never a secret
  the database holds. `handle_normalized` (lower, trimmed) carries the
  unique so "Tanweer@X" and "tanweer@x" are one channel.
  """

  def change do
    create table(:channels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(:kind, :string, null: false)
      add(:label, :string)
      add(:handle, :string, null: false)
      add(:handle_normalized, :string, null: false)
      add(:operated_by, :string, null: false)
      add(:listens_via, :string, null: false, default: "none")
      add(:inbound_address, :citext)
      add(:last_seen_at, :timestamptz)
      add(:status, :string, null: false, default: "active")
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:channels, :kind_known,
        check:
          "kind IN ('linkedin','upwork','indeed','fiverr','yc_waas','wellfound','email','other')"
      )
    )

    create(
      constraint(:channels, :operated_by_known,
        check: "operated_by IN ('customer','agency','staff_login')"
      )
    )

    create(
      constraint(:channels, :listens_via_known,
        check: "listens_via IN ('none','extension','forwarding','oauth')"
      )
    )

    create(
      constraint(:channels, :status_known, check: "status IN ('active','paused','disconnected')")
    )

    create(constraint(:channels, :handle_present, check: "btrim(handle) <> ''"))

    create(
      unique_index(:channels, [:customer_id, :kind, :handle_normalized],
        where: "archived_at IS NULL",
        name: :channels_live_handle_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON channels " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON channels"
    )
  end
end
