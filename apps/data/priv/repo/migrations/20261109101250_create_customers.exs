defmodule Data.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  @moduledoc """
  The people the team hunts for (AQ-01 §4.3). A customer is a business row
  first and a login second: `user_id` is null until the invitation is
  accepted, and `status` starts at `invited`. A customer in no team is
  allowed (QP1-8): onboarding happens before the team is chosen.

  Sits before `create_invitations` because an invitation of kind `customer`
  references this table; it references only organisations and users.
  """

  def change do
    create table(:customers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:display_name, :string, null: false)
      add(:email, :citext, null: false)
      add(:phone_e164, :string)
      add(:timezone, :string, null: false, default: "Asia/Karachi")
      add(:location_text, :string)
      add(:country_code, :string)
      add(:status, :string, null: false, default: "invited")
      add(:started_on, :date)
      add(:ended_on, :date)
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:customers, :status_known,
        check: "status IN ('invited','active','paused','ended')"
      )
    )

    create(constraint(:customers, :display_name_present, check: "btrim(display_name) <> ''"))
    create(unique_index(:customers, [:organisation_id, :email]))
    create(unique_index(:customers, [:user_id]))
    create(index(:customers, [:organisation_id, :status]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON customers " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON customers"
    )
  end
end
