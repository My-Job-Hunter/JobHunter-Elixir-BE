defmodule Data.Repo.Migrations.CreateJobSnapshots do
  use Ecto.Migration

  @moduledoc """
  The posting as written (AQ-03 §5.1, QP3-5): *Paste the posting* on the
  form now, a capture by the extension in P5. Kept as text, so a later
  parser can read it. The same body twice is one snapshot:
  `(job_id, body_sha256)` is unique. A merge moves them to the survivor.

  AQ-05 §5.4 (QP5-12): `fields` is a capture's raw fields as the adapter
  read them, as JSON text, so a parser fix can re-read old captures.
  """

  def change do
    create table(:job_snapshots, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:captured_at, :timestamptz, null: false)
      add(:captured_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:origin, :string, null: false, default: "manual")
      add(:content_type, :string, null: false, default: "text")
      add(:body, :text, null: false)
      add(:body_sha256, :string, null: false)
    end

    create(
      constraint(:job_snapshots, :origin_known,
        check: "origin IN ('manual','extension','email','import')"
      )
    )

    create(
      constraint(:job_snapshots, :content_type_known,
        check: "content_type IN ('text','html','fields')"
      )
    )

    create(constraint(:job_snapshots, :body_present, check: "btrim(body) <> ''"))

    create(
      constraint(:job_snapshots, :body_sha256_shape, check: "body_sha256 ~ '^[0-9a-f]{64}$'")
    )

    create(unique_index(:job_snapshots, [:job_id, :body_sha256]))
    create(index(:job_snapshots, [:job_id]))
    create(index(:job_snapshots, [:captured_by_user_id]))
  end
end
