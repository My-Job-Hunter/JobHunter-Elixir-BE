defmodule Data.Repo.Migrations.CreateApprovalVersionMedia do
  use Ecto.Migration

  @moduledoc """
  A version's files (AQ-07 §5.1): P1's three-step media and one link table
  per owner. **Each version holds its own set**, copied forward on a
  revision unless the revision names its own (`media_ids`), so version 1
  still shows what was asked of it. A purged lead's approvals take their
  files with them, bytes and all (§10).
  """

  def change do
    create table(:approval_version_media, primary_key: false) do
      add(
        :approval_version_id,
        references(:approval_versions, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:media_id, references(:media, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:position, :integer, null: false, default: 0)
    end

    create(index(:approval_version_media, [:media_id]))
  end
end
