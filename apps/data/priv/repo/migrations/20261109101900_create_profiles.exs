defmodule Data.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  @moduledoc """
  One way of marketing a customer (JH-01 §4.3; PLAN §4): a title, a pitch,
  skills, a CV. "Golang backend" and "MERN full-stack" are two profiles of
  one customer. `(customer_id, title)` is unique while the profile is live.

  The **pitch** (title, headline, summary) and the **facts** (everything
  else) are split by `Core.Access` (QP1-7): a member edits facts, a lead or
  the customer edits the pitch. The money floor is minor units + currency +
  period, never summed across currencies (CONVENTIONS §3).

  The array columns are checked against the vocabulary with `<@`: a value
  outside `Data.Vocabulary` cannot be written from psql either.

  The default CV is not a column: `documents` points at `profiles`, so a
  `default_document_id` here could not carry its foreign key in this
  `create`. It is the link table `profile_default_documents`, created after
  `documents` — one link table per owner.
  """

  def change do
    create table(:profiles, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(:title, :string, null: false)
      add(:headline, :string)
      add(:summary_md, :text)
      add(:seniority, :string)
      add(:years_experience, :smallint)
      add(:engagement_types, {:array, :text}, null: false, default: [])
      add(:workplace_types, {:array, :text}, null: false, default: [])
      add(:min_comp_minor, :bigint)
      add(:min_comp_currency, :string)
      add(:min_comp_period, :string)
      add(:work_timezones, {:array, :text}, null: false, default: [])
      add(:work_countries, {:array, :text}, null: false, default: [])
      add(:visa_note, :string)
      add(:notice_days, :smallint)
      add(:available_from_on, :date)
      add(:daily_target, :smallint, null: false, default: 35)
      add(:default_pipeline_key, :string, null: false, default: "employment")
      add(:status, :string, null: false, default: "active")
      add(:archived_at, :timestamptz)

      timestamps()
    end

    create(constraint(:profiles, :title_present, check: "btrim(title) <> ''"))

    create(
      constraint(:profiles, :seniority_known,
        check:
          "seniority IS NULL OR seniority IN ('entry','associate','mid_senior','director'," <>
            "'executive','internship','not_applicable')"
      )
    )

    create(
      constraint(:profiles, :engagement_types_known,
        check:
          "engagement_types <@ ARRAY['full_time','part_time','contract','freelance_hourly'," <>
            "'freelance_fixed','internship','temporary','other']::text[]"
      )
    )

    create(
      constraint(:profiles, :workplace_types_known,
        check: "workplace_types <@ ARRAY['remote','hybrid','on_site','unknown']::text[]"
      )
    )

    create(
      constraint(:profiles, :min_comp_period_known,
        check:
          "min_comp_period IS NULL OR min_comp_period IN ('hour','day','week','month','year','project')"
      )
    )

    create(
      constraint(:profiles, :min_comp_whole,
        check:
          "(min_comp_minor IS NULL AND min_comp_currency IS NULL AND min_comp_period IS NULL) OR " <>
            "(min_comp_minor IS NOT NULL AND min_comp_minor >= 0 AND " <>
            "min_comp_currency IS NOT NULL AND min_comp_period IS NOT NULL)"
      )
    )

    create(
      constraint(:profiles, :years_experience_not_negative,
        check: "years_experience IS NULL OR years_experience >= 0"
      )
    )

    create(constraint(:profiles, :daily_target_not_negative, check: "daily_target >= 0"))

    create(
      constraint(:profiles, :default_pipeline_key_known,
        check: "default_pipeline_key IN ('employment','freelance')"
      )
    )

    create(constraint(:profiles, :status_known, check: "status IN ('active','paused')"))

    create(
      unique_index(:profiles, [:customer_id, :title],
        where: "archived_at IS NULL",
        name: :profiles_live_title_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON profiles " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON profiles"
    )
  end
end
