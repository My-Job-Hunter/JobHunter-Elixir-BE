defmodule Data.Repo.Migrations.CreateExtensionConfigs do
  use Ecto.Migration

  @moduledoc """
  The selector documents (AQ-05 §5.2, QP5-21): each site's versions, as
  published from `apps/core/priv/extension/<site>.json` by the reference
  seed and `mix aq.ext_config`. `body` is the file's text byte for byte,
  so `sha256` — the `ETag` the extension revalidates with — is its digest.
  The highest version of a site is the live one. **No `organisation_id`**:
  it is the deployment's reference data, like the notification kinds.
  """

  def change do
    create table(:extension_configs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:site, :string, null: false)
      add(:version, :integer, null: false)
      add(:body, :text, null: false)
      add(:sha256, :string, null: false)
      add(:published_at, :timestamptz, null: false)
    end

    create(constraint(:extension_configs, :site_known, check: "site IN ('linkedin','upwork')"))
    create(constraint(:extension_configs, :version_positive, check: "version >= 1"))

    create(constraint(:extension_configs, :sha256_shape, check: "sha256 ~ '^[0-9a-f]{64}$'"))

    create(constraint(:extension_configs, :body_present, check: "btrim(body) <> ''"))

    create(unique_index(:extension_configs, [:site, :version]))
    create(unique_index(:extension_configs, [:site, :sha256]))
  end
end
