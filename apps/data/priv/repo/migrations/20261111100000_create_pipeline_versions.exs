defmodule Data.Repo.Migrations.CreatePipelineVersions do
  use Ecto.Migration

  @moduledoc """
  A version of one of the organisation's two pipelines (AQ-04A §5.1, §9,
  QP4a-2): `employment` or `freelance`, numbered from 1. **The newest number
  is the live one**; a lead keeps the version it started on (mCart's
  stage templates). Version 1 of each is written from the code's defaults
  by `Core.Leads.Pipelines.ensure/2`; every save in Settings › Pipelines is
  the next number. Append-only, so no `updated_at`.
  """

  def change do
    create table(:pipeline_versions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:pipeline_key, :text, null: false)
      add(:number, :smallint, null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:pipeline_versions, :pipeline_key_known,
        check: "pipeline_key IN ('employment','freelance')"
      )
    )

    create(constraint(:pipeline_versions, :number_positive, check: "number >= 1"))
    create(unique_index(:pipeline_versions, [:organisation_id, :pipeline_key, :number]))
    create(index(:pipeline_versions, [:created_by_user_id]))
  end
end
