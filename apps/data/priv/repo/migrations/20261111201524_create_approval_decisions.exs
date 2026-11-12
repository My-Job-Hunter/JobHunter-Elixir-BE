defmodule Data.Repo.Migrations.CreateApprovalDecisions do
  use Ecto.Migration

  @moduledoc """
  The decisions (AQ-07 §5.2, QP7-6): **one per slot per version**, so a
  revision opens every slot again and every version's decisions stay — who
  said what to which words is the point of a round trip. A note is required
  with *changes requested* and *rejected* ("What should change?", "Why
  not?"). `decided_by_user_id` is the customer's own user or the lead who
  took the slot; none when the system approved it (auto-approve, §9).
  """

  @decisions ~w(approved changes_requested rejected)

  def change do
    create table(:approval_decisions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:approval_id, references(:approvals, type: :uuid, on_delete: :delete_all), null: false)

      add(
        :approval_reviewer_id,
        references(:approval_reviewers, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:version_number, :smallint, null: false)
      add(:decision, :text, null: false)
      add(:note, :text)
      add(:decided_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:decided_at, :timestamptz, null: false)
    end

    create(
      constraint(:approval_decisions, :decision_known, check: "decision IN (#{list(@decisions)})")
    )

    create(
      constraint(:approval_decisions, :note_with_refusal,
        check: "decision = 'approved' OR (note IS NOT NULL AND btrim(note) <> '')"
      )
    )

    create(
      constraint(:approval_decisions, :note_length,
        check: "note IS NULL OR char_length(note) <= 2000"
      )
    )

    create(constraint(:approval_decisions, :version_whole, check: "version_number >= 1"))

    create(unique_index(:approval_decisions, [:approval_reviewer_id, :version_number]))
    create(index(:approval_decisions, [:approval_id, :version_number]))
    create(index(:approval_decisions, [:decided_by_user_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
