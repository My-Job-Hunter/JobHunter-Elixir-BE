defmodule Data.Repo.Migrations.CreateInboundMessages do
  use Ecto.Migration

  @moduledoc """
  The intake log (AQ-09 §5, §6.2, QP9-8): one row per delivery the
  webhook (or `POST /dev/inbound`) accepted, **whatever became of it** —
  `landed`, `duplicate`, `unknown_address`, `gmail_confirmation`,
  `unreadable`, `too_large` — so "did my forward arrive?" has an answer.
  No bodies: the address, the ids, the size and the outcome.

  `organisation_id` and `channel_id` are null when the address names no
  channel. `(provider, provider_message_id)` is unique: a provider's retry
  of the same delivery adds no row. `message_id` is the message a landed
  (or duplicate) mail is. Kept 30 days (`Core.Workers.InboundSweep`).
  """

  @providers ~w(postmark dev)
  @outcomes ~w(landed duplicate unknown_address gmail_confirmation unreadable too_large)

  def change do
    create table(:inbound_messages, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all))
      add(:channel_id, references(:channels, type: :uuid, on_delete: :nilify_all))
      add(:provider, :text, null: false)
      add(:provider_message_id, :text)
      add(:rfc_message_id, :text)
      add(:to_address, :citext)
      add(:outcome, :text, null: false)
      add(:message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:bytes, :bigint, null: false, default: 0)
      add(:received_at, :timestamptz, null: false)
    end

    create(
      constraint(:inbound_messages, :provider_known, check: "provider IN (#{list(@providers)})")
    )

    create(
      constraint(:inbound_messages, :outcome_known, check: "outcome IN (#{list(@outcomes)})")
    )

    create(constraint(:inbound_messages, :bytes_whole, check: "bytes >= 0"))

    create(
      unique_index(:inbound_messages, [:provider, :provider_message_id],
        where: "provider_message_id IS NOT NULL",
        name: :inbound_messages_delivery_index
      )
    )

    create(index(:inbound_messages, [:channel_id]))
    create(index(:inbound_messages, [:received_at]))
    create(index(:inbound_messages, [:organisation_id]))
    create(index(:inbound_messages, [:message_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
