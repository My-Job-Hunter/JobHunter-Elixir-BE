defmodule Data.Repo.Migrations.CreateApprovalVersions do
  use Ecto.Migration

  @moduledoc """
  An approval's versions (AQ-07 §5.1, QP7-3, QP7-6): version 1 is drafted
  with the approval, and each revision adds the next (`number`), **never
  changing an earlier one**, so every decision stays read against the words
  it saw. The diff between two versions is computed on read (QP7-8).

  **The proposed value is typed columns, never `jsonb`** (D1): the CV
  (`proposed_document_id`, `cv_for_job`), the bid and Connects
  (`proposal`), the expectation (`rate`), the pitch fields and skills
  (`profile_change`) — what the effect applies through the existing verbs
  (§7). `approval_kind` is the approval's, copied here so a CHECK per group
  can hold each `proposed_*` to its kind; money travels with its currency
  and period, or not at all.

  The body is markdown (≤ 20,000). The files are `approval_version_media`.
  """

  @kinds ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  @bid_periods ~w(hour project)
  @comp_periods ~w(hour day week month year project)

  def change do
    create table(:approval_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:approval_id, references(:approvals, type: :uuid, on_delete: :delete_all), null: false)

      add(:approval_kind, :text, null: false)
      add(:number, :smallint, null: false)
      add(:body_md, :text, null: false, default: "")
      add(:proposed_document_id, references(:documents, type: :uuid, on_delete: :nilify_all))
      add(:proposed_bid_minor, :bigint)
      add(:proposed_bid_currency, :text)
      add(:proposed_bid_period, :text)
      add(:proposed_connects, :integer)
      add(:proposed_expectation_minor, :bigint)
      add(:proposed_expectation_currency, :text)
      add(:proposed_expectation_period, :text)
      add(:proposed_title, :text)
      add(:proposed_headline, :text)
      add(:proposed_summary, :text)
      add(:proposed_skill_ids, {:array, :uuid})
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false)
    end

    create(
      constraint(:approval_versions, :approval_kind_known,
        check: "approval_kind IN (#{list(@kinds)})"
      )
    )

    create(
      constraint(:approval_versions, :proposed_bid_period_known,
        check: "proposed_bid_period IS NULL OR proposed_bid_period IN (#{list(@bid_periods)})"
      )
    )

    create(
      constraint(:approval_versions, :proposed_expectation_period_known,
        check:
          "proposed_expectation_period IS NULL OR " <>
            "proposed_expectation_period IN (#{list(@comp_periods)})"
      )
    )

    create(constraint(:approval_versions, :number_whole, check: "number >= 1"))
    create(constraint(:approval_versions, :body_length, check: "char_length(body_md) <= 20000"))

    # Money with its currency and period, or none of them.
    create(
      constraint(:approval_versions, :bid_together,
        check:
          "num_nonnulls(proposed_bid_minor, proposed_bid_currency, proposed_bid_period) IN (0, 3)"
      )
    )

    create(
      constraint(:approval_versions, :expectation_together,
        check:
          "num_nonnulls(proposed_expectation_minor, proposed_expectation_currency, " <>
            "proposed_expectation_period) IN (0, 3)"
      )
    )

    create(
      constraint(:approval_versions, :amounts_whole,
        check:
          "(proposed_bid_minor IS NULL OR proposed_bid_minor >= 0) AND " <>
            "(proposed_expectation_minor IS NULL OR proposed_expectation_minor >= 0) AND " <>
            "(proposed_connects IS NULL OR proposed_connects BETWEEN 0 AND 32767)"
      )
    )

    # A CHECK per group (§5.1): each proposed value only for its kind.
    create(
      constraint(:approval_versions, :cv_only_cv_for_job,
        check: "proposed_document_id IS NULL OR approval_kind = 'cv_for_job'"
      )
    )

    create(
      constraint(:approval_versions, :bid_only_proposal,
        check:
          "num_nonnulls(proposed_bid_minor, proposed_bid_currency, proposed_bid_period, " <>
            "proposed_connects) = 0 OR approval_kind = 'proposal'"
      )
    )

    create(
      constraint(:approval_versions, :expectation_only_rate,
        check:
          "num_nonnulls(proposed_expectation_minor, proposed_expectation_currency, " <>
            "proposed_expectation_period) = 0 OR approval_kind = 'rate'"
      )
    )

    create(
      constraint(:approval_versions, :pitch_only_profile_change,
        check:
          "num_nonnulls(proposed_title, proposed_headline, proposed_summary, " <>
            "proposed_skill_ids) = 0 OR approval_kind = 'profile_change'"
      )
    )

    create(unique_index(:approval_versions, [:approval_id, :number]))
    create(index(:approval_versions, [:proposed_document_id]))
    create(index(:approval_versions, [:created_by_user_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
