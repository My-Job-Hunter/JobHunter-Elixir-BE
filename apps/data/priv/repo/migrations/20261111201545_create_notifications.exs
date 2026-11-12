defmodule Data.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @moduledoc """
  One person's notification (AQ-02 §5.2): **ensured** by `(user_id,
  dedupe_key)`, never blindly created (`Data.Notifications.ensure/2`), so a
  scan that runs every five minutes tells somebody once. The words are
  **frozen at write in the recipient's terms** — a customer whose team hides
  staff names reads "The team gave you…" for ever.

  **One subject column per kind of subject**, never a `kind + id` pair
  (PLAN §16): `task_id` (P2) and `lead_id` (AQ-04A §5.4), at most one of them
  (`one_subject`); AQ-07 §5.4 adds `approval_id` (P7's notifications name
  their approval, not its lead) to the same CHECK, so this runs **after
  `create_approvals`**. P6's meetings and conversations name their lead
  (QP2-15). Delivery beyond the app is P8's own table.
  """

  def change do
    create table(:notifications, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      add(
        :notification_kind_key,
        references(:notification_kinds, column: :key, type: :string, on_delete: :restrict),
        null: false
      )

      add(:actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:task_id, references(:tasks, type: :uuid, on_delete: :delete_all))
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all))
      add(:approval_id, references(:approvals, type: :uuid, on_delete: :delete_all))
      add(:title, :string, null: false)
      add(:body, :text)
      add(:link_path, :string)
      add(:dedupe_key, :string, null: false)
      add(:read_at, :timestamptz)

      timestamps()
    end

    create(constraint(:notifications, :title_present, check: "btrim(title) <> ''"))

    create(
      constraint(:notifications, :one_subject,
        check: "num_nonnulls(task_id, lead_id, approval_id) <= 1"
      )
    )

    # What `ensure` rests on.
    create(unique_index(:notifications, [:user_id, :dedupe_key]))
    create(index(:notifications, [:user_id, "inserted_at DESC"]))

    # The bell.
    create(
      index(:notifications, [:user_id],
        where: "read_at IS NULL",
        name: :notifications_unread_index
      )
    )

    create(index(:notifications, [:organisation_id]))
    create(index(:notifications, [:notification_kind_key]))
    create(index(:notifications, [:actor_user_id]))
    create(index(:notifications, [:task_id]))
    create(index(:notifications, [:lead_id]))
    create(index(:notifications, [:approval_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON notifications " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON notifications"
    )
  end
end
