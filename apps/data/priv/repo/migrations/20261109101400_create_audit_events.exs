defmodule Data.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  @moduledoc """
  Who did what, on what, before → after (AQ-01 §4.2). Written by
  `Core.Audit.record/4` inside the same transaction as the write it records.

  **The one place a `kind + id` pair is allowed** (mCart §8a D3: audit
  logs): `subject_kind` is the table name, `subject_id` the row. Kept forever
  in P1 (QP1-11).
  """

  def change do
    create table(:audit_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:via, :string, null: false)
      add(:subject_kind, :string, null: false)
      add(:subject_id, :uuid, null: false)
      add(:action, :string, null: false)
      add(:before, :map)
      add(:after, :map)
      add(:request_id, :string)
      add(:occurred_at, :timestamptz, null: false)
    end

    create(
      constraint(:audit_events, :via_known, check: "via IN ('web','extension','task','system')")
    )

    create(index(:audit_events, [:organisation_id, "occurred_at DESC"]))
    create(index(:audit_events, [:subject_kind, :subject_id]))
    create(index(:audit_events, [:actor_user_id]))
  end
end
