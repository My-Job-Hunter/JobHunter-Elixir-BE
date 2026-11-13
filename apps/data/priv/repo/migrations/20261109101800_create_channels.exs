defmodule Data.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  @moduledoc """
  A customer's platform accounts (AQ-01 §4.3): the LinkedIn, the Upwork,
  the inbox the team works through. A channel belongs to the customer and
  is linked to the profiles that work through it (`profile_channels`).

  **No credential column exists** (PLAN Q3): who operates the account is
  `operated_by`; a staff login is a risk the screen names, never a secret
  the database holds. `handle_normalized` (lower, trimmed) carries the
  unique so "Tanweer@X" and "tanweer@x" are one channel.

  **`identity_key`** (AQ-05 §5.4, QP5-8) is the account itself, from
  `Utils.ChannelKey` (`linkedin:tanweer`, `upwork:~01aa…`; null for an inbox
  or a site the rules don't know): unique per kind among live channels,
  because one account belongs to one person, whichever customer typed it.

  **`inbound_token`** (AQ-09 §5, §6.1, QP9-5): an email channel's
  forwarding address is `in+<token>@<inbound domain>`, built from the
  token and `config :core, :inbound` (one fact, one place), so no address
  is stored. Ten characters (`a–z`, `2–9`, no look-alikes), unique, set
  when an email channel is made and replaced by *New address*; **an email
  channel always has one and no other kind ever does**. `last_inbound_at`
  is the last mail that landed through it.
  """

  def change do
    create table(:channels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(:kind, :string, null: false)
      add(:label, :string)
      add(:handle, :string, null: false)
      add(:handle_normalized, :string, null: false)
      add(:identity_key, :string)
      add(:operated_by, :string, null: false)
      add(:listens_via, :string, null: false, default: "none")
      add(:inbound_token, :citext)
      add(:last_inbound_at, :timestamptz)
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
      constraint(:channels, :inbound_token_only_email,
        check: "(inbound_token IS NOT NULL) = (kind = 'email')"
      )
    )

    create(
      unique_index(:channels, [:inbound_token],
        where: "inbound_token IS NOT NULL",
        name: :channels_inbound_token_index
      )
    )

    create(
      unique_index(:channels, [:customer_id, :kind, :handle_normalized],
        where: "archived_at IS NULL",
        name: :channels_live_handle_index
      )
    )

    create(
      unique_index(:channels, [:kind, :identity_key],
        where: "archived_at IS NULL AND identity_key IS NOT NULL",
        name: :channels_live_identity_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON channels " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON channels"
    )
  end
end
