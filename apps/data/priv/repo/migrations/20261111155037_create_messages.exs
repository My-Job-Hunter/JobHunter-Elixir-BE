defmodule Data.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  @moduledoc """
  One message of a conversation (AQ-06 §5.2, §11.6), mCart's
  `conversation_messages` kept: `is_internal` staff notes, the author as
  typed keys with a CHECK, tombstones (`deleted_at`).

  **Who wrote it** is `from_kind` (§11.6): `contact` with
  `from_contact_id`, `user` with `from_user_id`, `customer` (the
  conversation's customer, no key) or `text` with `from_text` as written —
  each key set exactly for its kind. `from_text` and `to_text` keep what a
  header said ("Mei Chen <mei.chen@juniperedge.example>") whatever the kind.

  **The tree** is `parent_message_id` (QP6-7): *Replies to* by hand, and
  for an `.eml` `In-Reply-To`'s message, else the last of `references` we
  hold. A child whose parent has not arrived keeps the headers and is
  re-parented when it does. `rfc_message_id` is indexed for exactly that.

  `idempotency_key` is unique in the organisation (PLAN §16): an `.eml`'s
  `Message-ID`, a captured message's platform id or hash, so the same
  message twice adds nothing. `source_media_id` is the uploaded `.eml` a
  message was read from (a purge deletes it with the attachments).

  An internal note is always `out`, by a user, typed by hand; only a
  hand-typed message is edited or deleted (QP6-8), and a deleted one keeps
  its place in the tree with no body.
  """

  @directions ~w(in out)
  @from_kinds ~w(contact user customer text)
  @captures ~w(manual eml_upload extension forward oauth_sync)
  @classes ~w(interested interview_invitation more_info rejection position_closed unsubscribe
              bounce general)

  def change do
    create table(:messages, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:direction, :text, null: false)
      add(:is_internal, :boolean, null: false, default: false)
      add(:from_kind, :text, null: false)
      add(:from_contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all))
      add(:from_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:from_text, :text)
      add(:to_text, :text)
      add(:sent_at, :timestamptz, null: false)
      add(:body_text, :text)
      add(:body_html, :text)
      add(:parent_message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:rfc_message_id, :text)
      add(:in_reply_to, :text)
      add(:references, {:array, :text}, null: false, default: [])
      add(:captured_via, :text, null: false)
      add(:idempotency_key, :text)
      add(:source_media_id, references(:media, type: :uuid, on_delete: :nilify_all))
      add(:classification, :text)
      add(:classified_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:edited_at, :timestamptz)
      add(:deleted_at, :timestamptz)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:messages, :direction_known, check: "direction IN (#{list(@directions)})"))
    create(constraint(:messages, :from_kind_known, check: "from_kind IN (#{list(@from_kinds)})"))

    create(
      constraint(:messages, :captured_via_known, check: "captured_via IN (#{list(@captures)})")
    )

    create(
      constraint(:messages, :classification_known,
        check: "classification IS NULL OR classification IN (#{list(@classes)})"
      )
    )

    create(
      constraint(:messages, :one_author,
        check: "num_nonnulls(from_contact_id, from_user_id) <= 1"
      )
    )

    # §11.6: each author key exactly for its kind; a `text` author says who.
    create(
      constraint(:messages, :from_matches_kind,
        check:
          "(from_kind = 'contact') = (from_contact_id IS NOT NULL) AND " <>
            "(from_kind = 'user') = (from_user_id IS NOT NULL) AND " <>
            "(from_kind <> 'text' OR (from_text IS NOT NULL AND btrim(from_text) <> ''))"
      )
    )

    create(
      constraint(:messages, :internal_note_shape,
        check:
          "NOT is_internal OR " <>
            "(direction = 'out' AND from_kind = 'user' AND captured_via = 'manual')"
      )
    )

    create(
      constraint(:messages, :body_present,
        check: "deleted_at IS NOT NULL OR (body_text IS NOT NULL AND btrim(body_text) <> '')"
      )
    )

    create(
      constraint(:messages, :not_its_own_parent,
        check: "parent_message_id IS NULL OR parent_message_id <> id"
      )
    )

    create(unique_index(:messages, [:organisation_id, :idempotency_key]))
    create(index(:messages, [:conversation_id, :sent_at]))
    create(index(:messages, [:organisation_id, :rfc_message_id]))
    create(index(:messages, [:from_contact_id]))
    create(index(:messages, [:from_user_id]))
    create(index(:messages, [:parent_message_id]))
    create(index(:messages, [:source_media_id]))
    create(index(:messages, [:classified_by_user_id]))
    create(index(:messages, [:created_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON messages " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON messages"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
