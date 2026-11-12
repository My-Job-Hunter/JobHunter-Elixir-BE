defmodule Data.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  @moduledoc """
  The deliveries ledger (AQ-08 §5, QP8-2): **one row per notification and
  channel beyond the bell** — `push`, `email`, `extension` — planned in the
  notification's own transaction by `Core.Notifications.ensure/2`. In-app is
  the notification row itself, and `digest` is read by the scan, so neither
  has a row here. **Unique `(notification_id, channel)`: never twice.**

  - `deliver_after`: push and pop-ups at once, email ten minutes on (the
    meetings' and the account's at once); inside quiet hours the window's
    end, with `deferred` set (held, never dropped, QP8-8).
  - `state` ∈ `pending · sent · skipped · failed`; `skip_reason` ∈ `read ·
    no_target · preference_off`, set exactly when skipped; `sent_at`
    exactly when sent. A failure keeps its `error` (at most 500 characters,
    never a body) and counts `attempts`; the third makes it `failed`.
  - `ics`: the meeting's calendar file, frozen at write, on the email row
    of `meetings.scheduled` and `meetings.changed` only — how `core` hands
    `notifire` the bytes without either calling the other.

  `organisation_id` is here for delivery health (§9). The rows go with
  their notification (a purged lead's take theirs) and with their person
  (QP8-21).
  """

  @channels ~w(push email extension)
  @states ~w(pending sent skipped failed)
  @skip_reasons ~w(read no_target preference_off)

  def change do
    create table(:notification_deliveries, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:notification_id, references(:notifications, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:channel, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:deliver_after, :timestamptz, null: false)
      add(:deferred, :boolean, null: false, default: false)
      add(:skip_reason, :text)
      add(:error, :text)
      add(:attempts, :smallint, null: false, default: 0)
      add(:sent_at, :timestamptz)
      add(:ics, :text)

      timestamps()
    end

    create(
      constraint(:notification_deliveries, :channel_known,
        check: "channel IN (#{list(@channels)})"
      )
    )

    create(
      constraint(:notification_deliveries, :state_known, check: "state IN (#{list(@states)})")
    )

    create(
      constraint(:notification_deliveries, :skip_reason_known,
        check: "skip_reason IS NULL OR skip_reason IN (#{list(@skip_reasons)})"
      )
    )

    create(
      constraint(:notification_deliveries, :skipped_with_reason,
        check: "(state = 'skipped') = (skip_reason IS NOT NULL)"
      )
    )

    create(
      constraint(:notification_deliveries, :sent_with_time,
        check: "(state = 'sent') = (sent_at IS NOT NULL)"
      )
    )

    create(
      constraint(:notification_deliveries, :error_short,
        check: "error IS NULL OR char_length(error) <= 500"
      )
    )

    create(constraint(:notification_deliveries, :attempts_counted, check: "attempts >= 0"))

    create(
      constraint(:notification_deliveries, :ics_on_email,
        check: "ics IS NULL OR channel = 'email'"
      )
    )

    # Never twice.
    create(unique_index(:notification_deliveries, [:notification_id, :channel]))

    # What the sweep takes: the due rows still waiting.
    create(
      index(:notification_deliveries, [:deliver_after],
        where: "state = 'pending'",
        name: :notification_deliveries_pending_index
      )
    )

    create(index(:notification_deliveries, [:user_id]))
    # Delivery health: an organisation's last 24 hours.
    create(index(:notification_deliveries, [:organisation_id, :inserted_at]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON notification_deliveries " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON notification_deliveries"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
