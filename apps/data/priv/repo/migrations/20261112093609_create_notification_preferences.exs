defmodule Data.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  @moduledoc """
  A person's switches for one notification group (AQ-08 §5, §8, QP8-6;
  mCart's shape with AutoQare's four channels): push, email, the extension
  and the digest, each on unless turned off. **Off-only**: a switch off
  stops that channel for the group's kinds; on brings back the kinds'
  defaults. A row is written when a person first changes a switch for that
  group; **no row means all on**. In-app is always on, and a group with
  `can_disable: false` (Account) takes no row.

  A person's own, like `user_settings`: no organisation, gone with the
  person (QP8-21).
  """

  def change do
    create table(:notification_preferences, primary_key: false) do
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :notification_group_key,
        references(:notification_groups, column: :key, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:is_push_on, :boolean, null: false, default: true)
      add(:is_email_on, :boolean, null: false, default: true)
      add(:is_extension_on, :boolean, null: false, default: true)
      add(:is_digest_on, :boolean, null: false, default: true)
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(index(:notification_preferences, [:notification_group_key]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON notification_preferences " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON notification_preferences"
    )
  end
end
