defmodule Data.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  @moduledoc """
  The front door (AQ-01 §3, §4.2). Nobody signs up on their own: every account
  begins here. An invitation names what the person becomes — an **admin**,
  a **team member** (team + role) or a **customer** (the customer record,
  made first by staff).

  Codes are `XX-XXXX` from an alphabet with no 0/O or 1/I (CHECK), seven days
  to live (QP1-1), one use. A CHECK ties `team_id`/`role` to `team_member`
  and `customer_id` to `customer`. **At most one open invitation per
  target**: three partial unique indexes, one per kind, because a nullable
  column in one index would let two admin invitations for one address stand.

  `customers` is created just before this (it references only organisations
  and users), so `customer_id` is a real reference here.
  """

  @open "accepted_at IS NULL AND revoked_at IS NULL"

  def change do
    create table(:invitations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:code, :string, null: false)
      add(:email, :citext, null: false)
      add(:invited_name, :string)
      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all))
      add(:role, :string)
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all))
      add(:invited_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:expires_at, :timestamptz, null: false)
      add(:accepted_at, :timestamptz)
      add(:accepted_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:revoked_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:invitations, :kind_known, check: "kind IN ('admin','team_member','customer')")
    )

    create(
      constraint(:invitations, :role_known, check: "role IS NULL OR role IN ('lead','member')")
    )

    create(
      constraint(:invitations, :code_shape,
        check: "code ~ '^[A-HJ-NP-Z2-9]{2}-[A-HJ-NP-Z2-9]{4}$'"
      )
    )

    create(
      constraint(:invitations, :kind_fields_match,
        check: """
        (kind = 'team_member' AND team_id IS NOT NULL AND role IS NOT NULL AND customer_id IS NULL)
        OR (kind = 'customer' AND customer_id IS NOT NULL AND team_id IS NULL AND role IS NULL)
        OR (kind = 'admin' AND team_id IS NULL AND role IS NULL AND customer_id IS NULL)
        """
      )
    )

    create(unique_index(:invitations, [:code]))

    create(
      unique_index(:invitations, [:organisation_id, :email],
        where: "kind = 'admin' AND #{@open}",
        name: :invitations_one_open_admin_index
      )
    )

    create(
      unique_index(:invitations, [:email, :team_id],
        where: "kind = 'team_member' AND #{@open}",
        name: :invitations_one_open_team_member_index
      )
    )

    create(
      unique_index(:invitations, [:email, :customer_id],
        where: "kind = 'customer' AND #{@open}",
        name: :invitations_one_open_customer_index
      )
    )

    create(index(:invitations, [:organisation_id]))
    create(index(:invitations, [:team_id]))
    create(index(:invitations, [:customer_id]))
    create(index(:invitations, [:invited_by_user_id]))
    create(index(:invitations, [:accepted_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON invitations " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON invitations"
    )
  end
end
