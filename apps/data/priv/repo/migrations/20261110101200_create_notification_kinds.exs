defmodule Data.Repo.Migrations.CreateNotificationKinds do
  use Ecto.Migration

  @moduledoc """
  Every event that raises a notification (AQ-02 §5.2, §8; mCart's):
  `tasks.assigned`, `tasks.overdue`. The key names its group, and a CHECK
  holds the two together. `default_channels` are PLAN §11's, seeded now so
  P8 reads them without a migration; in-app is always among them.
  """

  def change do
    create table(:notification_kinds, primary_key: false) do
      add(:key, :string, primary_key: true)

      add(
        :notification_group_key,
        references(:notification_groups, column: :key, type: :string, on_delete: :restrict),
        null: false
      )

      add(:default_channels, {:array, :string}, null: false, default: ["inapp"])
      add(:can_ignore_quiet_hours, :boolean, null: false, default: false)
    end

    create(
      constraint(:notification_kinds, :key_names_its_group,
        check:
          "key ~ '^[a-z_]+\\.[a-z0-9_]+$' AND starts_with(key, notification_group_key || '.')"
      )
    )

    create(
      constraint(:notification_kinds, :default_channels_known,
        check:
          "default_channels <@ ARRAY['inapp','push','email','extension','digest']::varchar[] " <>
            "AND 'inapp' = ANY(default_channels)"
      )
    )

    create(index(:notification_kinds, [:notification_group_key]))
  end
end
