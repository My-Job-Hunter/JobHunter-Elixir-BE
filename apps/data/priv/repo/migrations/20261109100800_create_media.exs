defmodule Data.Repo.Migrations.CreateMedia do
  use Ecto.Migration

  @moduledoc """
  Every stored file (JH-01 §4.1): the file and nothing else. What a file is
  attached to is a link table per owner: `person_photos` (the next
  migration), `document_media` (P1.2).

  The three-step upload (AutoCare's): `POST /media` reserves a row,
  `PUT /media/:id/blob` stores and sniffs the bytes against the allowlist,
  `POST /media/:id/confirm` marks `uploaded_at`. `sha256` is null until the
  bytes arrive and is computed from them. Unconfirmed rows older than a day
  are swept.
  """

  def change do
    create table(:media, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:owner_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:media_kind, :string, null: false)
      add(:storage_key, :string, null: false)
      add(:content_type, :string, null: false)
      add(:byte_count, :bigint, null: false)
      add(:sha256, :binary)
      add(:width_px, :integer)
      add(:height_px, :integer)
      add(:page_count, :integer)
      add(:original_filename, :string)
      add(:uploaded_at, :timestamptz)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:media, :media_kind_known,
        check: "media_kind IN ('photo','document','attachment')"
      )
    )

    create(constraint(:media, :byte_count_positive, check: "byte_count > 0"))
    create(unique_index(:media, [:storage_key]))
    create(index(:media, [:organisation_id]))
    create(index(:media, [:owner_user_id]))
    # The sweep of unconfirmed rows.
    create(
      index(:media, [:inserted_at], where: "uploaded_at IS NULL", name: :media_pending_index)
    )
  end
end
