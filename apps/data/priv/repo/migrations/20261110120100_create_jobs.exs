defmodule Data.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  @moduledoc """
  The job pool (AQ-03 §5.1; PLAN §5): one row per posting, **in one team's
  pool** (AQ-03B §4: `team_id` restricts, since a team is archived, never
  deleted; `organisation_id` stays, as on every business row). **The
  canonical key is the identity**: `Utils.JobKey` makes it from the link,
  and `(team_id, canonical_key)` is unique, so two people of a team adding
  the same link meet the index, never a second row (§6.3); another team
  holds its own copy. A merged job's key lives on in
  `job_merges` (QP3-8).

  The columns come in schema.org `JobPosting`'s groups: identity, what,
  where, engagement, money, applying, lifecycle. Everything but the link
  and the title may stay unknown. Money is minor units with its currency
  and period, never converted (CONVENTIONS §3); an estimate is
  `comp_source = 'platform_estimate'` (QP3-9), not a flag of its own.
  `description_html` is a capture's, sanitised (P5); the form writes
  `description_md` (QP3-14). Closing is a verb with `closed_at` held to
  the status; archiving is a flag, as a task's is.

  The array columns are checked in the database: country codes by shape,
  regions against the vocabulary with `<@`.
  """

  def change do
    create table(:jobs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      # Identity
      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :restrict), null: false)
      add(:source, :string, null: false)
      add(:source_url, :text, null: false)
      add(:canonical_key, :text, null: false)
      add(:source_job_id, :string)
      add(:origin, :string, null: false, default: "manual")
      add(:first_seen_at, :timestamptz, null: false)
      add(:last_seen_at, :timestamptz, null: false)
      add(:is_reposted, :boolean, null: false, default: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      # What
      add(:company_id, references(:companies, type: :uuid, on_delete: :restrict))
      add(:poster_name, :string)
      add(:title, :string, null: false)
      add(:description_md, :text)
      add(:description_html, :text)
      add(:seniority, :string)
      add(:category, :string)
      add(:openings, :smallint)

      # Where
      add(:workplace, :string)
      add(:remote_scope, :string)
      add(:allowed_countries, {:array, :text}, null: false, default: [])
      add(:allowed_regions, {:array, :text}, null: false, default: [])
      add(:required_timezones, {:array, :text}, null: false, default: [])
      add(:min_overlap_hours, :smallint)
      add(:overlap_from_time, :time)
      add(:overlap_to_time, :time)
      add(:onsite_locations, {:array, :text}, null: false, default: [])
      add(:is_relocation_offered, :boolean)
      add(:visa, :string)
      add(:visa_text, :text)

      # Engagement
      add(:engagement, :string)
      add(:duration, :string)
      add(:hours_min, :smallint)
      add(:hours_max, :smallint)
      add(:start_on, :date)
      add(:is_immediate_start, :boolean, null: false, default: false)

      # Money
      add(:comp_min_minor, :bigint)
      add(:comp_max_minor, :bigint)
      add(:comp_currency, :string)
      add(:comp_period, :string)
      add(:comp_source, :string)
      add(:comp_text, :text)
      add(:is_comp_undisclosed, :boolean, null: false, default: false)
      add(:equity_min_bp, :smallint)
      add(:equity_max_bp, :smallint)
      add(:equity_kind, :string)

      # Applying
      add(:apply_method, :string)
      add(:apply_url, :text)

      # Lifecycle
      add(:posted_on, :date)
      add(:valid_through_on, :date)
      add(:status, :string, null: false, default: "open")
      add(:closed_at, :timestamptz)
      add(:closed_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:close_reason, :string)
      add(:last_activity_at, :timestamptz)
      add(:archived_at, :timestamptz)
      add(:archived_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(
      constraint(:jobs, :source_known,
        check:
          "source IN ('linkedin','upwork','indeed','yc_waas','wellfound','fiverr','greenhouse'," <>
            "'lever','ashby','workable','company_site','email','other')"
      )
    )

    create(
      constraint(:jobs, :origin_known, check: "origin IN ('manual','extension','email','import')")
    )

    create(
      constraint(:jobs, :seniority_known,
        check:
          "seniority IS NULL OR seniority IN ('entry','associate','mid_senior','director'," <>
            "'executive','internship','not_applicable')"
      )
    )

    create(
      constraint(:jobs, :workplace_known,
        check: "workplace IS NULL OR workplace IN ('remote','hybrid','on_site','unknown')"
      )
    )

    create(
      constraint(:jobs, :remote_scope_known,
        check:
          "remote_scope IS NULL OR remote_scope IN ('global','region','country_list','unknown')"
      )
    )

    create(
      constraint(:jobs, :visa_known,
        check: "visa IS NULL OR visa IN ('yes','no','existing_auth_only','unknown')"
      )
    )

    create(
      constraint(:jobs, :engagement_known,
        check:
          "engagement IS NULL OR engagement IN ('full_time','part_time','contract'," <>
            "'freelance_hourly','freelance_fixed','internship','temporary','other')"
      )
    )

    create(
      constraint(:jobs, :duration_known,
        check: "duration IS NULL OR duration IN ('lt_1m','1_3m','3_6m','gt_6m')"
      )
    )

    create(
      constraint(:jobs, :comp_period_known,
        check:
          "comp_period IS NULL OR comp_period IN ('hour','day','week','month','year','project')"
      )
    )

    create(
      constraint(:jobs, :comp_source_known,
        check:
          "comp_source IS NULL OR comp_source IN ('employer','platform_estimate','parsed_text')"
      )
    )

    create(
      constraint(:jobs, :equity_kind_known,
        check: "equity_kind IS NULL OR equity_kind IN ('options','rsu','profit_share','unknown')"
      )
    )

    create(
      constraint(:jobs, :apply_method_known,
        check:
          "apply_method IS NULL OR apply_method IN ('in_platform_easy','external_ats','proposal'," <>
            "'email','brief_response','referral','recruiter_inbound','other')"
      )
    )

    create(constraint(:jobs, :status_known, check: "status IN ('open','closed','unknown')"))

    create(
      constraint(:jobs, :close_reason_known,
        check: "close_reason IS NULL OR close_reason IN ('filled','expired','withdrawn','other')"
      )
    )

    create(
      constraint(:jobs, :title_present, check: "btrim(title) <> '' AND char_length(title) <= 300")
    )

    create(
      constraint(:jobs, :comp_range,
        check:
          "comp_min_minor IS NULL OR comp_max_minor IS NULL OR comp_min_minor <= comp_max_minor"
      )
    )

    create(
      constraint(:jobs, :comp_not_negative,
        check:
          "(comp_min_minor IS NULL OR comp_min_minor >= 0) AND " <>
            "(comp_max_minor IS NULL OR comp_max_minor >= 0)"
      )
    )

    # An amount means nothing without its currency and its period.
    create(
      constraint(:jobs, :comp_whole,
        check:
          "(comp_min_minor IS NULL AND comp_max_minor IS NULL) OR " <>
            "(comp_currency ~ '^[A-Z]{3}$' AND comp_period IS NOT NULL)"
      )
    )

    create(
      constraint(:jobs, :comp_currency_iso,
        check: "comp_currency IS NULL OR comp_currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:jobs, :equity_range,
        check:
          "(equity_min_bp IS NULL OR equity_min_bp BETWEEN 0 AND 10000) AND " <>
            "(equity_max_bp IS NULL OR equity_max_bp BETWEEN 0 AND 10000) AND " <>
            "(equity_min_bp IS NULL OR equity_max_bp IS NULL OR equity_min_bp <= equity_max_bp)"
      )
    )

    create(
      constraint(:jobs, :hours_range,
        check:
          "(hours_min IS NULL OR hours_min >= 0) AND (hours_max IS NULL OR hours_max >= 0) AND " <>
            "(hours_min IS NULL OR hours_max IS NULL OR hours_min <= hours_max)"
      )
    )

    create(constraint(:jobs, :openings_positive, check: "openings IS NULL OR openings >= 1"))

    create(
      constraint(:jobs, :min_overlap_hours_range,
        check: "min_overlap_hours IS NULL OR min_overlap_hours BETWEEN 0 AND 24"
      )
    )

    # Each code two capital letters: an array has no per-element CHECK, so
    # the joined list is held to the shape instead.
    create(
      constraint(:jobs, :allowed_countries_iso,
        check: "array_to_string(allowed_countries, ',') ~ '^([A-Z]{2}(,[A-Z]{2})*)?$'"
      )
    )

    create(
      constraint(:jobs, :allowed_regions_known,
        check:
          "allowed_regions <@ ARRAY['europe','eu','uk_ireland','north_america','us','canada'," <>
            "'latam','emea','apac','mena','south_asia','africa','oceania']::text[]"
      )
    )

    create(
      constraint(:jobs, :closed_matches_status,
        check: "(status = 'closed') = (closed_at IS NOT NULL)"
      )
    )

    create(
      constraint(:jobs, :close_reason_only_closed,
        check: "close_reason IS NULL OR status = 'closed'"
      )
    )

    create(unique_index(:jobs, [:team_id, :canonical_key]))

    create(index(:jobs, ["title gin_trgm_ops"], using: :gin, name: :jobs_title_trgm_index))

    create(
      index(:jobs, ["team_id", "status", "first_seen_at DESC"],
        name: :jobs_team_id_status_first_seen_at_index
      )
    )

    create(index(:jobs, [:organisation_id, :archived_at]))
    create(index(:jobs, [:company_id]))
    create(index(:jobs, [:created_by_user_id]))
    create(index(:jobs, [:closed_by_user_id]))
    create(index(:jobs, [:archived_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON jobs " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON jobs"
    )
  end
end
