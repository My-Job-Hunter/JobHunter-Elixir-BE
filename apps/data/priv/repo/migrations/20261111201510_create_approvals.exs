defmodule Data.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  @moduledoc """
  An approval (AQ-07 §5.1, PLAN §9): a question put to the customer, a team
  lead or a named person — *may I send this reply, set this CV, quote this
  rate?* — with versions, reviewer slots, decisions per version and comments
  in their own tables.

  **In a team** (QP7-1: the lead's; for a profile change the requester's
  team serving the customer) **and about a customer**. What it is about is
  typed keys, at most the ones its kind needs (`subject_for_kind`): a lead
  for `cv_for_job · proposal · rate · asset` (optional for `cover_letter`
  and `other`), a profile for `profile_change`, a lead or a conversation for
  `reply` — whose `message_id` is the message it answers. A purged lead
  takes its approvals (PLAN §6.8); a profile's stay with the profile.

  **Its life** (§6): `draft → pending → approved · changes_requested ·
  rejected · withdrawn · expired`; `submitted_at` once past a draft (a
  draft may be withdrawn unsent). `version_count` is the current version's
  number. `rule` is *any* or *all* over the slots (QP7-5); `due_at` and
  `auto_approve_at` drive the reminders, the expiry and auto-approve (§9).

  **What approval did** (§7, §11.4): `effect` ∈ `none · ready · sent ·
  applied · failed`, set only on an approved one; a `failed` effect keeps
  its reason in `effect_note` ("the lead is archived") — the decision
  stands (QP7-11).
  """

  @kinds ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  @states ~w(draft pending approved changes_requested rejected withdrawn expired)
  @rules ~w(any all)
  @effects ~w(none ready sent applied failed)

  def change do
    create table(:approvals, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)
      add(:approval_kind, :text, null: false)
      add(:state, :text, null: false, default: "draft")
      add(:title, :text, null: false)
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all))
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all))
      add(:message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :nilify_all))
      add(:rule, :text, null: false, default: "any")
      add(:due_at, :timestamptz)
      add(:auto_approve_at, :timestamptz)
      add(:requested_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:submitted_at, :timestamptz)
      add(:decided_at, :timestamptz)
      add(:version_count, :smallint, null: false, default: 1)
      add(:effect, :text, null: false, default: "none")
      add(:effect_note, :text)
      add(:effect_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:approvals, :approval_kind_known, check: "approval_kind IN (#{list(@kinds)})")
    )

    create(constraint(:approvals, :state_known, check: "state IN (#{list(@states)})"))
    create(constraint(:approvals, :rule_known, check: "rule IN (#{list(@rules)})"))
    create(constraint(:approvals, :effect_known, check: "effect IN (#{list(@effects)})"))

    create(
      constraint(:approvals, :title_present,
        check: "btrim(title) <> '' AND char_length(title) <= 200"
      )
    )

    # What it is about, by kind (§5.1): at most the keys its kind needs.
    create(
      constraint(:approvals, :subject_for_kind,
        check:
          "CASE " <>
            "WHEN approval_kind = 'profile_change' THEN profile_id IS NOT NULL AND lead_id IS NULL " <>
            "WHEN approval_kind = 'reply' THEN profile_id IS NULL AND " <>
            "(lead_id IS NOT NULL OR conversation_id IS NOT NULL) " <>
            "WHEN approval_kind IN ('cv_for_job','proposal','rate','asset') THEN " <>
            "profile_id IS NULL AND lead_id IS NOT NULL " <>
            "ELSE profile_id IS NULL END"
      )
    )

    create(
      constraint(:approvals, :thread_only_reply,
        check: "approval_kind = 'reply' OR (message_id IS NULL AND conversation_id IS NULL)"
      )
    )

    create(
      constraint(:approvals, :submitted_past_draft,
        check:
          "(state <> 'draft' OR submitted_at IS NULL) AND " <>
            "(state IN ('draft','withdrawn') OR submitted_at IS NOT NULL)"
      )
    )

    create(constraint(:approvals, :version_count_whole, check: "version_count >= 1"))

    create(
      constraint(:approvals, :effect_once_approved,
        check: "effect = 'none' OR state = 'approved'"
      )
    )

    create(
      constraint(:approvals, :failed_with_reason,
        check: "effect <> 'failed' OR (effect_note IS NOT NULL AND btrim(effect_note) <> '')"
      )
    )

    create(index(:approvals, [:team_id, :state, :due_at]))
    create(index(:approvals, [:organisation_id]))
    create(index(:approvals, [:customer_id, :state]))
    create(index(:approvals, [:lead_id]))
    create(index(:approvals, [:profile_id]))
    create(index(:approvals, [:message_id]))
    create(index(:approvals, [:conversation_id]))
    create(index(:approvals, [:requested_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON approvals " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON approvals"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
