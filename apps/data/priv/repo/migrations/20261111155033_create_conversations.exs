defmodule Data.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  @moduledoc """
  A conversation (AQ-06 §5.2, QP6-5): an email thread, a LinkedIn chat, an
  Upwork room, or one typed by hand. **In one team, like everything**
  (P3b): it links only to that team's leads, and its triage is that
  team's. `customer_id` is the customer it is about — null in triage until
  a lead says. `external_thread_id` is the provider's thread (a Gmail
  `threadId`, a LinkedIn thread, an Upwork room): **a hint that joins a
  conversation, never the tree** (QP6-7), unique per team and platform.

  **Triage is derived** (QP6-9): a conversation linked to no lead and not
  ignored (`ignored_at`) is the team's triage item; there is no table.
  """

  @platforms ~w(linkedin upwork indeed fiverr yc_waas wellfound email other)

  def change do
    create table(:conversations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all))
      add(:channel_id, references(:channels, type: :uuid, on_delete: :nilify_all))
      add(:platform, :text, null: false)
      add(:external_thread_id, :text)
      add(:subject, :text)
      add(:last_message_at, :timestamptz)
      add(:ignored_at, :timestamptz)
      add(:ignored_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(
      constraint(:conversations, :platform_known, check: "platform IN (#{list(@platforms)})")
    )

    create(
      constraint(:conversations, :subject_short,
        check: "subject IS NULL OR char_length(subject) <= 500"
      )
    )

    create(
      unique_index(:conversations, [:team_id, :platform, :external_thread_id],
        where: "external_thread_id IS NOT NULL",
        name: :conversations_thread_index
      )
    )

    create(index(:conversations, [:team_id, "last_message_at DESC"]))
    create(index(:conversations, [:organisation_id]))
    create(index(:conversations, [:customer_id]))
    create(index(:conversations, [:channel_id]))
    create(index(:conversations, [:ignored_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON conversations " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON conversations"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
