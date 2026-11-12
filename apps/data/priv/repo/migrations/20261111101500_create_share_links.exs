defmodule Data.Repo.Migrations.CreateShareLinks do
  use Ecto.Migration

  @moduledoc """
  A share link (AQ-03B §3.3, §4): one task, job or lead shown read-only, at a
  level (`Data.Vocabulary.share_levels/0`), to any signed-in staff member of
  the organisation who holds the link. Exactly one subject: a task, a job
  or (AQ-04A QP4a-20) a lead.

  The token is 32 random bytes shown once; only its SHA-256 is kept, so the
  table cannot hand a link back. `expires_at` is optional (1 · 7 · 30 days,
  or never); `revoked_at` turns a link off for good. Made, opened (once per
  person per link per day) and revoked are audit rows.
  """

  def change do
    create table(:share_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all))
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all))
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all))
      add(:level, :text, null: false)
      add(:token_sha256, :binary, null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:expires_at, :timestamptz)
      add(:revoked_at, :timestamptz)
      add(:revoked_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(
      constraint(:share_links, :one_subject, check: "num_nonnulls(task_id, job_id, lead_id) = 1")
    )

    create(
      constraint(:share_links, :level_known,
        check: "level IN ('summary','details','details_history')"
      )
    )

    create(
      constraint(:share_links, :token_sha256_length, check: "octet_length(token_sha256) = 32")
    )

    create(
      constraint(:share_links, :revoked_together,
        check: "revoked_by_user_id IS NULL OR revoked_at IS NOT NULL"
      )
    )

    create(unique_index(:share_links, [:token_sha256]))
    create(index(:share_links, [:organisation_id]))
    create(index(:share_links, [:task_id]))
    create(index(:share_links, [:job_id]))
    create(index(:share_links, [:lead_id]))
    create(index(:share_links, [:created_by_user_id]))
    create(index(:share_links, [:revoked_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON share_links " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON share_links"
    )
  end
end
