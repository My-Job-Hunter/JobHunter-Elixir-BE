defmodule Data.Repo.Migrations.CreateContactMerges do
  use Ecto.Migration

  @moduledoc """
  A contact merged into another (AQ-06 §6, QP6-4), P3's `job_merges`
  pattern: every handle, lead link, participation, meeting attendance and
  message author moved to the survivor in one transaction, and this row
  keeps what the merged contact was called and the handles it had. The
  merged contact's own row stays, with `merged_into_contact_id` set, so an
  old link still resolves.
  """

  def change do
    create table(:contact_merges, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:into_contact_id, references(:contacts, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:from_name, :text, null: false)
      add(:from_handles, {:array, :text}, null: false, default: [])
      add(:merged_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:merged_at, :timestamptz, null: false)
    end

    create(index(:contact_merges, [:into_contact_id]))
    create(index(:contact_merges, [:organisation_id]))
    create(index(:contact_merges, [:merged_by_user_id]))
  end
end
