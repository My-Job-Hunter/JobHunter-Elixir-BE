defmodule Data.Repo.Migrations.CreateMessageMedia do
  use Ecto.Migration

  @moduledoc """
  A message's attachments (AQ-06 §5.2, §7.1): P1's one link table per
  owner. An `.eml`'s attachments go through P1's media — bytes sniffed
  against the allowlist — and are linked here in their order, with the
  name the email gave them. A purged conversation's files go with it,
  bytes and all (§10).
  """

  def change do
    create table(:message_media, primary_key: false) do
      add(:message_id, references(:messages, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:media_id, references(:media, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:filename, :text)
      add(:position, :integer, null: false, default: 0)
    end

    create(index(:message_media, [:media_id]))
  end
end
