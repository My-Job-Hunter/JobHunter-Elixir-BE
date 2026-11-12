defmodule Data.Repo.Migrations.CreateCustomerApprovalPolicies do
  use Ecto.Migration

  @moduledoc """
  A customer's approval rules (AQ-07 §5.3, §8, QP7-16; PLAN Q12): **only
  the overrides are stored** — Q12's defaults are code
  (`Core.Approvals.Policies`), as mCart keeps its settings 1:1 with
  defaults. Per customer, across every team (one set of rules); edited by a
  team lead of a team serving them, or the system admin. `needs` makes the
  slots (`both`: customer and team lead), `rule` is *any* or *all*, and
  `auto_approve_hours` approves a pending one by itself after that long
  (null: off, QP7-14).
  """

  @kinds ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  @needs ~w(customer team_lead both ad_hoc)
  @rules ~w(any all)

  def change do
    create table(:customer_approval_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)
      add(:approval_kind, :text, null: false)
      add(:needs, :text, null: false)
      add(:rule, :text, null: false)
      add(:auto_approve_hours, :integer)
      add(:updated_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(
      constraint(:customer_approval_policies, :approval_kind_known,
        check: "approval_kind IN (#{list(@kinds)})"
      )
    )

    create(
      constraint(:customer_approval_policies, :needs_known, check: "needs IN (#{list(@needs)})")
    )

    create(
      constraint(:customer_approval_policies, :rule_known, check: "rule IN (#{list(@rules)})")
    )

    create(
      constraint(:customer_approval_policies, :auto_approve_hours_range,
        check: "auto_approve_hours IS NULL OR auto_approve_hours BETWEEN 1 AND 168"
      )
    )

    create(unique_index(:customer_approval_policies, [:customer_id, :approval_kind]))
    create(index(:customer_approval_policies, [:organisation_id]))
    create(index(:customer_approval_policies, [:updated_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON customer_approval_policies " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON customer_approval_policies"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
