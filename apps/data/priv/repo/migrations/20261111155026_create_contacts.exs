defmodule Data.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  @moduledoc """
  The people on the other side (AQ-06 §5.1, QP6-2): recruiters, hiring
  managers, interviewers, clients. **The organisation's, not a team's**: a
  recruiter works with several teams, and one contact keeps one history.
  Every staff member reads and adds them; the customer reads only names
  and roles on their own leads.

  `name_normalized` (lower, unaccented, spaces collapsed — made by
  `Data.Contacts.Contact`) carries a trigram index for the match check's
  *possible* answer (PLAN §16). A merged contact keeps its row with
  `merged_into_contact_id` set, so old links resolve, as P3's merged jobs
  do (QP6-4).
  """

  @sources ~w(manual email extension import)

  def change do
    create table(:contacts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:name_normalized, :text, null: false)
      add(:title, :text)
      add(:company_id, references(:companies, type: :uuid, on_delete: :nilify_all))
      add(:time_zone, :text)
      add(:location, :text)
      add(:source, :text, null: false, default: "manual")
      add(:is_do_not_contact, :boolean, null: false, default: false)
      add(:merged_into_contact_id, references(:contacts, type: :uuid, on_delete: :nilify_all))
      add(:notes_md, :text)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(
      constraint(:contacts, :name_present,
        check: "btrim(name) <> '' AND char_length(name) <= 200"
      )
    )

    create(constraint(:contacts, :source_known, check: "source IN (#{list(@sources)})"))

    create(
      constraint(:contacts, :not_merged_into_itself,
        check: "merged_into_contact_id IS NULL OR merged_into_contact_id <> id"
      )
    )

    create(index(:contacts, [:organisation_id, :company_id]))
    create(index(:contacts, [:organisation_id, :name_normalized]))
    create(index(:contacts, [:company_id]))
    create(index(:contacts, [:merged_into_contact_id]))
    create(index(:contacts, [:created_by_user_id]))

    create(
      index(:contacts, ["name_normalized gin_trgm_ops"],
        using: :gin,
        name: :contacts_name_normalized_trgm_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON contacts " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON contacts"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
