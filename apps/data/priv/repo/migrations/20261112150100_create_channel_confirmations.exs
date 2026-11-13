defmodule Data.Repo.Migrations.CreateChannelConfirmations do
  use Ecto.Migration

  @moduledoc """
  Gmail's forwarding check (AQ-09 §8, QP9-11): Gmail won't forward until
  the forwarding address confirms, and mails a code and a link from
  `forwarding-noreply@google.com`. The mail is never a conversation; its
  code and link land here, shown on the channel's sheet in both apps,
  and are **cleared** (`cleared_at`) when the first real mail arrives
  through the address. **One open per channel**: a second check replaces
  the first.
  """

  def change do
    create table(:channel_confirmations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:channel_id, references(:channels, type: :uuid, on_delete: :delete_all), null: false)
      add(:code, :text)
      add(:confirm_url, :text)
      add(:received_at, :timestamptz, null: false)
      add(:cleared_at, :timestamptz)
    end

    create(
      constraint(:channel_confirmations, :code_or_url,
        check: "code IS NOT NULL OR confirm_url IS NOT NULL"
      )
    )

    create(
      unique_index(:channel_confirmations, [:channel_id],
        where: "cleared_at IS NULL",
        name: :channel_confirmations_open_index
      )
    )
  end
end
