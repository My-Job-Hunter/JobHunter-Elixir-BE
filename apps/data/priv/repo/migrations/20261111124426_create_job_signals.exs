defmodule Data.Repo.Migrations.CreateJobSignals do
  use Ecto.Migration

  @moduledoc """
  What moves on a posting (AQ-05 §5.3, QP5-14): the applicants, the
  proposals, the interviews, the invites, the hires and when the client
  last looked, as the extension read them. Typed columns, a time series
  never on the job row (PLAN §5.2). **A row is written only when a fact
  differs from the job's latest row**, so a view that saw nothing new adds
  nothing. `proposals_max` is null for "50+".
  """

  @counts ~w(applicant_count proposals_min proposals_max interviewing invites_sent
             unanswered_invites hires)a

  def change do
    create table(:job_signals, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:job_id, references(:jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:observed_at, :timestamptz, null: false)
      add(:observed_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:applicant_count, :smallint)
      add(:is_applicant_count_capped, :boolean)
      add(:proposals_min, :smallint)
      add(:proposals_max, :smallint)
      add(:interviewing, :smallint)
      add(:invites_sent, :smallint)
      add(:unanswered_invites, :smallint)
      add(:hires, :smallint)
      add(:client_last_viewed_at, :timestamptz)
    end

    for count <- @counts do
      create(
        constraint(:job_signals, :"#{count}_not_negative",
          check: "#{count} IS NULL OR #{count} >= 0"
        )
      )
    end

    create(
      constraint(:job_signals, :proposals_range,
        check: "proposals_min IS NULL OR proposals_max IS NULL OR proposals_min <= proposals_max"
      )
    )

    create(
      constraint(:job_signals, :a_fact_is_set,
        check:
          "num_nonnulls(applicant_count, proposals_min, proposals_max, interviewing, " <>
            "invites_sent, unanswered_invites, hires, client_last_viewed_at) >= 1"
      )
    )

    create(index(:job_signals, [:job_id, "observed_at DESC"]))
    create(index(:job_signals, [:organisation_id]))
    create(index(:job_signals, [:observed_by_user_id]))
  end
end
