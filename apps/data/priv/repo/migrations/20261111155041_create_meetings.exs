defmodule Data.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  @moduledoc """
  A lead's meetings (AQ-06 §5.3, §8): a screening, a technical interview, a
  client call — on Zoom, Google Meet, Upwork, the phone. **Times are UTC
  with the IANA zone they were set in** (`time_zone`), so every screen can
  show both sides ("Tue 14:00 PKT · 10:00 CET").

  Four statuses (QP6-15): `scheduled · done · cancelled · no_show`. **A
  reschedule is an event, not a status**: new times, `sequence` + 1 (the
  ICS file's), `meeting_changed`, and the reminders re-planned. The
  partial index on scheduled meetings serves the reminders, the Meetings
  page and the clash warning. A purged lead takes its meetings.

  **`proposed`** (AQ-09 §9, QP9-12): a meeting an invitation (`.ics`)
  proposed, waiting for a person's *Confirm*: no reminders, no notices to
  the customer. Only an invitation proposes (`source = email_invite`).
  `from_message_id` is the mail it came in; `proposal` is what the
  invitation said, frozen (`{organizer, method, uid, sequence}`), plus a
  `change` an updated or cancelled invitation proposes on a confirmed
  meeting.
  """

  @kinds ~w(screening technical assessment_review ai_interview final client_call other)
  @platforms ~w(zoom google_meet teams upwork phone on_site other)
  @statuses ~w(proposed scheduled done cancelled no_show)
  @sources ~w(manual email_invite extension)

  def change do
    create table(:meetings, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), null: false)
      add(:title, :text, null: false)
      add(:meeting_kind, :text, null: false)
      add(:platform, :text, null: false)
      add(:join_url, :text)
      add(:address, :text)
      add(:starts_at, :timestamptz, null: false)
      add(:ends_at, :timestamptz, null: false)
      add(:time_zone, :text, null: false)
      add(:status, :text, null: false, default: "scheduled")
      add(:outcome_note, :text)
      add(:notes_md, :text)
      add(:source, :text, null: false, default: "manual")
      add(:sequence, :integer, null: false, default: 0)
      add(:from_message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:proposal, :map)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:meetings, :meeting_kind_known, check: "meeting_kind IN (#{list(@kinds)})"))
    create(constraint(:meetings, :platform_known, check: "platform IN (#{list(@platforms)})"))
    create(constraint(:meetings, :status_known, check: "status IN (#{list(@statuses)})"))
    create(constraint(:meetings, :source_known, check: "source IN (#{list(@sources)})"))
    create(constraint(:meetings, :ends_after_starts, check: "ends_at > starts_at"))

    create(
      constraint(:meetings, :title_present,
        check: "btrim(title) <> '' AND char_length(title) <= 200"
      )
    )

    create(constraint(:meetings, :sequence_whole, check: "sequence >= 0"))

    create(
      constraint(:meetings, :proposed_from_invite,
        check: "status <> 'proposed' OR source = 'email_invite'"
      )
    )

    create(index(:meetings, [:lead_id, :starts_at]))

    create(
      index(:meetings, [:organisation_id, :starts_at],
        where: "status = 'scheduled'",
        name: :meetings_scheduled_index
      )
    )

    create(index(:meetings, [:created_by_user_id]))
    create(index(:meetings, [:from_message_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON meetings " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON meetings"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
