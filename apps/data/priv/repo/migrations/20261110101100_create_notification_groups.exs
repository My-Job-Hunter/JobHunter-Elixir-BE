defmodule Data.Repo.Migrations.CreateNotificationGroups do
  use Ecto.Migration

  @moduledoc """
  What a notification is about, for the chips and (P8) the preferences
  (AQ-02 §5.2; mCart's). **Data, seeded** (`Data.Seeds.Notifications`):
  a later phase adds its group as a seed row, not a migration. P2 seeds
  `tasks`.
  """

  def change do
    create table(:notification_groups, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:label, :string, null: false)
      add(:position, :smallint, null: false, default: 0)
      add(:can_disable, :boolean, null: false, default: true)
    end

    create(constraint(:notification_groups, :key_shape, check: "key ~ '^[a-z_]+$'"))
    create(constraint(:notification_groups, :label_present, check: "btrim(label) <> ''"))
  end
end
