defmodule Data.Repo.Migrations.CreateExtensionMisses do
  use Ecto.Migration

  @moduledoc """
  The selector health (AQ-05 §5.2, QP5-22): how often a selector missed,
  per organisation, site, selector, config version, extension version and
  day (`seen_on`, in the organisation's zone). A report adds to `count`
  on the unique row. **No address and no page text**: what broke and since
  when, nothing about anyone's browsing. `Core.Extension.MissSweep` deletes
  rows older than 30 days, hourly.
  """

  def change do
    create table(:extension_misses, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:site, :string, null: false)
      add(:page_kind, :string, null: false)
      add(:selector_key, :string, size: 60, null: false)
      add(:config_version, :integer, null: false)
      add(:extension_version, :string, size: 20, null: false)
      add(:seen_on, :date, null: false)
      add(:count, :integer, null: false)
      add(:first_seen_at, :timestamptz, null: false)
      add(:last_seen_at, :timestamptz, null: false)
    end

    create(constraint(:extension_misses, :site_known, check: "site IN ('linkedin','upwork')"))

    create(
      constraint(:extension_misses, :page_kind_known,
        check: "page_kind IN ('job','search','proposal','confirmation','thread','other')"
      )
    )

    create(constraint(:extension_misses, :count_positive, check: "count >= 1"))

    create(
      constraint(:extension_misses, :selector_key_shape,
        check: "selector_key ~ '^[a-z][a-z0-9_.]{0,59}$'"
      )
    )

    create(
      constraint(:extension_misses, :config_version_not_negative, check: "config_version >= 0")
    )

    create(
      unique_index(
        :extension_misses,
        [:organisation_id, :site, :selector_key, :config_version, :extension_version, :seen_on],
        name: :extension_misses_day_index
      )
    )

    create(index(:extension_misses, [:organisation_id]))
    create(index(:extension_misses, [:seen_on]))
  end
end
