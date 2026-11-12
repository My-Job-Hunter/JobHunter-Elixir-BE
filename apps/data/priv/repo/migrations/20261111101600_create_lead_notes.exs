defmodule Data.Repo.Migrations.CreateLeadNotes do
  use Ecto.Migration

  @moduledoc """
  A lead's notes (AQ-04B §5.1, QP4b-13): the team's thinking about a lead,
  in markdown, **staff only** — the customer never reads one. Each note
  writes a `note_added` row in the ledger (which points back at it with
  `lead_events.note_id`, so this table runs before `create_lead_events`).
  Its author or a team lead edits or deletes it; edits are audited, not
  events. A purged lead takes its notes with it.
  """

  def change do
    create table(:lead_notes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), null: false)
      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:body_md, :text, null: false)

      timestamps()
    end

    create(
      constraint(:lead_notes, :body_present,
        check: "btrim(body_md) <> '' AND char_length(body_md) <= 10000"
      )
    )

    create(index(:lead_notes, [:lead_id, "inserted_at DESC"]))
    create(index(:lead_notes, [:author_user_id]))
    create(index(:lead_notes, [:organisation_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON lead_notes " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON lead_notes"
    )
  end
end
