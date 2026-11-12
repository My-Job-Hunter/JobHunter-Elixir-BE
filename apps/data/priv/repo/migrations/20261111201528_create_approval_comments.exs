defmodule Data.Repo.Migrations.CreateApprovalComments do
  use Ecto.Migration

  @moduledoc """
  An approval's comments (AQ-07 §5.2, QP7-9): **one stream, read by every
  party to it** — the customer too when they hold a slot; there is no
  staff-only comment in P7. A deleted comment keeps its place with no body.
  """

  def change do
    create table(:approval_comments, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:approval_id, references(:approvals, type: :uuid, on_delete: :delete_all), null: false)

      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:body_md, :text, null: false, default: "")
      add(:deleted_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:approval_comments, :body_present,
        check: "deleted_at IS NOT NULL OR (btrim(body_md) <> '' AND char_length(body_md) <= 5000)"
      )
    )

    create(index(:approval_comments, [:approval_id, :inserted_at]))
    create(index(:approval_comments, [:author_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON approval_comments " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON approval_comments"
    )
  end
end
