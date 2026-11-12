defmodule Data.Repo.Migrations.CreateLeadEvents do
  use Ecto.Migration

  @moduledoc """
  A lead's ledger (AQ-04A §5.2, QP4a-4, QP4a-5; AQ-04B §5.3): **append-only**,
  one row per verb that moves or reassigns a lead, written in the verb's
  transaction and never updated. Typed columns, not a `data` blob (D1):
  the frozen words (`from_label`, `to_label`: "Applied", "Technical
  interview 1", "Fiza Malik"), an outcome, a note (a reason, as typed), the
  CV of a `cv_set`, and `is_again` on an apply-again's `applied`.
  `visibility` says whether the customer reads it (§7).

  P4b adds its kinds (`note_added · task_created · task_done ·
  follow_up_due · follow_up_logged · archive_warned · labelled`) and two
  keys, `task_id` and `note_id`, each nilified when its row goes: **at most
  one subject key is set** (PLAN §16). Re-timed after `create_tasks` and `create_lead_notes` for
  those keys.

  AQ-06 §5.4 (P6): the conversation and meeting kinds (`message_in ·
  message_out · conversation_linked · contact_linked · contact_unlinked ·
  meeting_scheduled · meeting_changed · meeting_done · meeting_cancelled ·
  classified`) and four more keys, `message_id`, `meeting_id`,
  `contact_id` and `conversation_id`, each nilified when its row goes; the
  CHECK holds at most one of the seven. **Re-timed after `create_contacts`,
  `create_conversations`, `create_messages` and `create_meetings`** for
  those keys.

  AQ-05 §5.4 (QP5-17): `request_id`, the extension's queued write that made
  the event, unique where set, so a retry of a write that landed answers
  the same lead. An `extension` event always names its person
  (`actor_user_with_person`).

  AQ-07 §5.4 (P7): `approval_requested · approval_decided ·
  approval_withdrawn` and the key `approval_id`, nilified when the approval
  goes, in the same at-most-one CHECK (a `cv_set` an approval made keeps
  its CV's `document_id` and names the approval in its `note`). **Re-timed
  after `create_approvals`** for that key.

  `lead_stage_visits` and `duplicate_overrides` are read from here: a
  `stage_moved` row is a visit, an `applied` row with `is_again` an override.
  """

  @kinds ~w(saved applied stage_moved state_moved outcome_set reopened owner_changed
            pipeline_changed cv_set archived unarchived note_added task_created task_done
            follow_up_due follow_up_logged archive_warned labelled message_in message_out
            conversation_linked contact_linked contact_unlinked meeting_scheduled meeting_changed
            meeting_done meeting_cancelled classified approval_requested approval_decided
            approval_withdrawn)
  @outcomes ~w(hired rejected withdrawn position_closed no_response not_pursued)

  def change do
    create table(:lead_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :text, null: false)
      add(:occurred_at, :timestamptz, null: false)
      add(:recorded_at, :timestamptz, null: false)
      add(:actor_kind, :text, null: false)
      add(:actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:visibility, :text, null: false)
      add(:from_label, :text)
      add(:to_label, :text)
      add(:outcome, :text)
      add(:note, :text)
      add(:document_id, references(:documents, type: :uuid, on_delete: :nilify_all))
      add(:task_id, references(:tasks, type: :uuid, on_delete: :nilify_all))
      add(:note_id, references(:lead_notes, type: :uuid, on_delete: :nilify_all))
      add(:message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:meeting_id, references(:meetings, type: :uuid, on_delete: :nilify_all))
      add(:contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all))
      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :nilify_all))
      add(:approval_id, references(:approvals, type: :uuid, on_delete: :nilify_all))
      add(:is_again, :boolean, null: false, default: false)
      add(:request_id, :uuid)
    end

    create(constraint(:lead_events, :kind_known, check: "kind IN (#{list(@kinds)})"))

    create(
      constraint(:lead_events, :actor_kind_known,
        check: "actor_kind IN ('user','customer','extension','email','system')"
      )
    )

    create(
      constraint(:lead_events, :visibility_known, check: "visibility IN ('staff','customer')")
    )

    create(
      constraint(:lead_events, :outcome_known,
        check: "outcome IS NULL OR outcome IN (#{list(@outcomes)})"
      )
    )

    create(
      constraint(:lead_events, :actor_user_with_person,
        check: "actor_kind NOT IN ('user','customer','extension') OR actor_user_id IS NOT NULL"
      )
    )

    create(
      constraint(:lead_events, :note_with_reason,
        check:
          "NOT ((kind = 'applied' AND is_again) OR (kind = 'state_moved' AND to_label = 'On hold')) " <>
            "OR (note IS NOT NULL AND btrim(note) <> '')"
      )
    )

    create(
      constraint(:lead_events, :again_only_applied, check: "NOT is_again OR kind = 'applied'")
    )

    # One subject at most (PLAN §16): the CV, the task, the note, the
    # message, the meeting, the contact, the conversation or the approval.
    create(
      constraint(:lead_events, :one_ref,
        check:
          "num_nonnulls(document_id, task_id, note_id, message_id, meeting_id, contact_id, " <>
            "conversation_id, approval_id) <= 1"
      )
    )

    create(
      unique_index(:lead_events, [:request_id],
        where: "request_id IS NOT NULL",
        name: :lead_events_request_id_index
      )
    )

    create(index(:lead_events, [:lead_id, "occurred_at DESC"]))
    create(index(:lead_events, [:organisation_id]))
    create(index(:lead_events, [:actor_user_id]))
    create(index(:lead_events, [:document_id]))
    create(index(:lead_events, [:task_id]))
    create(index(:lead_events, [:note_id]))
    create(index(:lead_events, [:message_id]))
    create(index(:lead_events, [:meeting_id]))
    create(index(:lead_events, [:contact_id]))
    create(index(:lead_events, [:conversation_id]))
    create(index(:lead_events, [:approval_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
