defmodule Data.Repo.Migrations.CreateApprovalReviewers do
  use Ecto.Migration

  @moduledoc """
  An approval's reviewers, as **slots** (AQ-07 §5.2, QP7-4): `customer` (the
  customer's own login decides it), `team_lead` (any lead of the approval's
  team may take it; who took it is the decision's `decided_by_user_id`) and
  `user` (a named staff member, `user_id`). From the customer's policy for
  the kind, or picked by the requester for an ad hoc kind (§8); one of
  each, a named person once (`NULLS NOT DISTINCT`).
  """

  @slots ~w(customer team_lead user)

  def change do
    create table(:approval_reviewers, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:approval_id, references(:approvals, type: :uuid, on_delete: :delete_all), null: false)

      add(:slot, :text, null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      add(:position, :integer, null: false, default: 0)
    end

    create(constraint(:approval_reviewers, :slot_known, check: "slot IN (#{list(@slots)})"))

    create(
      constraint(:approval_reviewers, :user_for_user_slot,
        check: "(slot = 'user') = (user_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:approval_reviewers, [:approval_id, :slot, :user_id],
        nulls_distinct: false,
        name: :approval_reviewers_slot_index
      )
    )

    create(index(:approval_reviewers, [:user_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
