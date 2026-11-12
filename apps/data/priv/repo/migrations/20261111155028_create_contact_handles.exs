defmodule Data.Repo.Migrations.CreateContactHandles do
  use Ecto.Migration

  @moduledoc """
  A contact's ways in (AQ-06 §5.1, QP6-3): an email, a LinkedIn, an Upwork
  account, a phone. `value` is as typed; `value_normalized` is what makes
  two spellings one account — an email lowercased, a LinkedIn or Upwork
  link by P5's `Utils.ChannelKey`, a phone's digits — made by
  `Data.Contacts.Handle`, so no caller can forget it. **One per (kind,
  normalised value) in the organisation** (PLAN §16): the match check's
  *exact* answer, and the 409 `contact_exists`. `is_invalid` is a bounce.
  """

  @kinds ~w(email linkedin upwork phone other)

  def change do
    create table(:contact_handles, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all), null: false)
      add(:kind, :text, null: false)
      add(:value, :text, null: false)
      add(:value_normalized, :text, null: false)
      add(:is_invalid, :boolean, null: false, default: false)

      timestamps()
    end

    create(constraint(:contact_handles, :kind_known, check: "kind IN (#{list(@kinds)})"))

    create(
      constraint(:contact_handles, :value_present,
        check:
          "btrim(value) <> '' AND char_length(value) <= 300 AND btrim(value_normalized) <> ''"
      )
    )

    create(unique_index(:contact_handles, [:organisation_id, :kind, :value_normalized]))
    create(index(:contact_handles, [:contact_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON contact_handles " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON contact_handles"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
