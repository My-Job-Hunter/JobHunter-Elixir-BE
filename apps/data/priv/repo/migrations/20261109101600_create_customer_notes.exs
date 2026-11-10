defmodule Data.Repo.Migrations.CreateCustomerNotes do
  use Ecto.Migration

  @moduledoc """
  Staff-only notes about a customer (JH-01 §4.3): never in the portal. A
  deleted note keeps its row with `deleted_at`, so the audit log's subject
  still resolves.
  """

  def change do
    create table(:customer_notes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:body_md, :text, null: false)
      add(:edited_at, :timestamptz)
      add(:deleted_at, :timestamptz)

      timestamps()
    end

    create(constraint(:customer_notes, :body_present, check: "btrim(body_md) <> ''"))
    create(index(:customer_notes, [:customer_id]))
    create(index(:customer_notes, [:author_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON customer_notes " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON customer_notes"
    )
  end
end
