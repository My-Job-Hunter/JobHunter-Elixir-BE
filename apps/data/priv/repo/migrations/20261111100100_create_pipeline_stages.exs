defmodule Data.Repo.Migrations.CreatePipelineStages do
  use Ecto.Migration

  @moduledoc """
  The stages of one pipeline version, in order (AQ-04A §5.1, §9.2). `key` is
  a slug **stable across versions** (`technical_1`), so a renamed stage keeps
  its leads' column and a removed one leaves a *retired* column (QP4a-3);
  a key is never reused for another stage. `kind` is an engine kind
  (`stage_kinds`) or `custom`; a custom stage names the engine kind it
  follows (`anchor_kind`). A stage's colour is its kind's, worked out by the
  frontend, so there is no colour column.
  """

  @kinds ~w(inbound applied seen screening assessment interview ai_interview final offer
            negotiation contract)

  def change do
    create table(:pipeline_stages, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :pipeline_version_id,
        references(:pipeline_versions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:key, :text, null: false)
      add(:name, :text, null: false)
      add(:kind, :text, null: false)
      add(:anchor_kind, :text)
      add(:position, :smallint, null: false)
    end

    create(constraint(:pipeline_stages, :name_present, check: "btrim(name) <> ''"))
    create(constraint(:pipeline_stages, :key_slug, check: "key ~ '^[a-z][a-z0-9_]{0,39}$'"))

    create(
      constraint(:pipeline_stages, :kind_known, check: "kind IN (#{list(@kinds ++ ["custom"])})")
    )

    create(
      constraint(:pipeline_stages, :anchor_kind_known,
        check: "anchor_kind IS NULL OR anchor_kind IN (#{list(@kinds)})"
      )
    )

    create(
      constraint(:pipeline_stages, :custom_anchored,
        check: "(kind = 'custom') = (anchor_kind IS NOT NULL)"
      )
    )

    create(unique_index(:pipeline_stages, [:pipeline_version_id, :key]))
    create(unique_index(:pipeline_stages, [:pipeline_version_id, :position]))
    create(index(:pipeline_stages, [:pipeline_version_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
