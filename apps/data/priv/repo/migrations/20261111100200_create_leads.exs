defmodule Data.Repo.Migrations.CreateLeads do
  use Ecto.Migration

  @moduledoc """
  A lead: one profile's application to one job (AQ-04A §5.2; PLAN §0). **A
  lead is in its job's team** (QP4a-8): a job never changes team, so there
  is no team column. One lead per profile per job (`(job_id, profile_id)`,
  Q33); across teams the posting is held by `Core.Leads.Guard` under an
  advisory lock.

  Four states (`todo · in_progress · on_hold · done`); archived is a flag
  with its reason (QP4a-1). In progress sits at a stage of the lead's own
  pipeline version; a lead keeps that version until *Change pipeline*.
  The application's facts (when, how, the CV, the letter, the bid and the
  expectation) are columns, written by hand in P4a and by P5's capture
  later (QP4a-19). Money is minor units with its currency and period.

  The CHECKs hold each state's columns to it: a stage exactly once applied
  (a lead finished from To do never had one), `held_at` with a reason on
  hold, an outcome and `finished_at` in Done, `applied_at` past To do except
  *Not pursued* and *Position closed* from To do.
  """

  @outcomes ~w(hired rejected withdrawn position_closed no_response not_pursued)
  @apply_methods ~w(in_platform_easy external_ats proposal email brief_response referral
                    recruiter_inbound other)
  @periods ~w(hour day week month year project)

  def change do
    create table(:leads, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:job_id, references(:jobs, type: :uuid, on_delete: :restrict), null: false)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:owner_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      add(:state, :text, null: false, default: "todo")

      add(
        :pipeline_version_id,
        references(:pipeline_versions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:stage_id, references(:pipeline_stages, type: :uuid, on_delete: :restrict))
      add(:priority, :text)

      add(:applied_at, :timestamptz)
      add(:applied_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:applied_via, :text)
      add(:applied_confirmation, :text)
      add(:document_id, references(:documents, type: :uuid, on_delete: :nilify_all))
      add(:cover_letter_md, :text)
      add(:bid_minor, :bigint)
      add(:bid_currency, :text)
      add(:bid_period, :text)
      add(:connects_spent, :smallint)
      add(:expectation_minor, :bigint)
      add(:expectation_currency, :text)
      add(:expectation_period, :text)

      add(:held_at, :timestamptz)
      add(:hold_reason, :text)
      add(:hold_until_on, :date)
      add(:outcome, :text)
      add(:outcome_note, :text)
      add(:finished_at, :timestamptz)

      add(:is_pinned, :boolean, null: false, default: false)
      add(:last_activity_at, :timestamptz, null: false)
      add(:archived_at, :timestamptz)
      add(:archived_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:archive_reason, :text)

      timestamps()
    end

    create(unique_index(:leads, [:job_id, :profile_id]))

    create(
      constraint(:leads, :state_known, check: "state IN ('todo','in_progress','on_hold','done')")
    )

    create(
      constraint(:leads, :priority_known,
        check: "priority IS NULL OR priority IN ('low','high','urgent')"
      )
    )

    create(
      constraint(:leads, :applied_via_known,
        check: "applied_via IS NULL OR applied_via IN (#{list(@apply_methods)})"
      )
    )

    create(
      constraint(:leads, :applied_confirmation_known,
        check:
          "applied_confirmation IS NULL OR " <>
            "applied_confirmation IN ('by_hand','page_confirmation','confirmation_email')"
      )
    )

    create(
      constraint(:leads, :bid_period_known,
        check: "bid_period IS NULL OR bid_period IN ('hour','project')"
      )
    )

    create(
      constraint(:leads, :expectation_period_known,
        check: "expectation_period IS NULL OR expectation_period IN (#{list(@periods)})"
      )
    )

    create(
      constraint(:leads, :outcome_known,
        check: "outcome IS NULL OR outcome IN (#{list(@outcomes)})"
      )
    )

    create(
      constraint(:leads, :archive_reason_known,
        check: "archive_reason IS NULL OR archive_reason IN ('by_hand','inactive')"
      )
    )

    # A stage exactly once the lead was applied: it never left To do otherwise.
    create(
      constraint(:leads, :stage_once_applied, check: "(stage_id IS NULL) = (applied_at IS NULL)")
    )

    create(
      constraint(:leads, :applied_past_todo,
        check:
          "(state = 'todo' AND applied_at IS NULL) OR " <>
            "(state IN ('in_progress','on_hold') AND applied_at IS NOT NULL) OR " <>
            "(state = 'done' AND (applied_at IS NOT NULL OR outcome IN ('not_pursued','position_closed')))"
      )
    )

    create(
      constraint(:leads, :held_with_reason,
        check:
          "(state = 'on_hold') = (held_at IS NOT NULL) AND " <>
            "(held_at IS NULL OR (hold_reason IS NOT NULL AND btrim(hold_reason) <> ''))"
      )
    )

    create(
      constraint(:leads, :hold_until_on_hold, check: "hold_until_on IS NULL OR state = 'on_hold'")
    )

    create(
      constraint(:leads, :done_with_outcome,
        check: "(state = 'done') = (finished_at IS NOT NULL AND outcome IS NOT NULL)"
      )
    )

    for money <- ~w(bid expectation) do
      create(
        constraint(:leads, :"#{money}_together",
          check:
            "(#{money}_minor IS NULL) = (#{money}_currency IS NULL) AND " <>
              "(#{money}_minor IS NULL) = (#{money}_period IS NULL)"
        )
      )

      create(
        constraint(:leads, :"#{money}_currency_iso",
          check: "#{money}_currency IS NULL OR #{money}_currency ~ '^[A-Z]{3}$'"
        )
      )

      create(
        constraint(:leads, :"#{money}_minor_whole",
          check: "#{money}_minor IS NULL OR #{money}_minor >= 0"
        )
      )
    end

    create(
      constraint(:leads, :connects_spent_whole,
        check: "connects_spent IS NULL OR connects_spent >= 0"
      )
    )

    create(
      constraint(:leads, :archived_together,
        check: "(archived_at IS NULL) = (archive_reason IS NULL)"
      )
    )

    # P4b's sweeps (PLAN §16) and the boards, which join the team's jobs.
    create(index(:leads, [:organisation_id, :state, :last_activity_at]))

    create(
      index(:leads, [:job_id, :state], where: "archived_at IS NULL", name: :leads_live_job_index)
    )

    create(index(:leads, [:profile_id]))
    create(index(:leads, [:owner_user_id]))
    create(index(:leads, [:created_by_user_id]))
    create(index(:leads, [:pipeline_version_id]))
    create(index(:leads, [:stage_id]))
    create(index(:leads, [:applied_by_user_id]))
    create(index(:leads, [:document_id]))
    create(index(:leads, [:archived_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON leads " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON leads"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
