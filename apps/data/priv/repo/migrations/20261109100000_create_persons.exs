defmodule Data.Repo.Migrations.CreatePersons do
  use Ecto.Migration

  @moduledoc """
  A human (AQ-01 §4.1). **A person is who; a user is a login.** One person may
  later hold two logins (a customer who is also staff: never in P1, kept
  possible), which is why the name, photo, timezone and locale live here and
  not on `users`.

  The photo is not a column here: `media` points at `users` which points at
  `persons`, so a `photo_media_id` could not carry its foreign key in this
  `create`. It is the link table `person_photos` instead — one link table
  per owner, the pattern `document_media` uses (AQ-01 §4.3).

  `timezone` defaults to the organisation's (QP1-2: Asia/Karachi); the code
  copies the organisation's zone in at account creation and the person may
  change it.
  """

  def change do
    create table(:persons, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:display_name, :string, null: false)
      add(:given_name, :string)
      add(:family_name, :string)
      add(:timezone, :string, null: false, default: "Asia/Karachi")
      add(:locale_code, :string, null: false, default: "en")

      timestamps()
    end

    create(constraint(:persons, :display_name_present, check: "btrim(display_name) <> ''"))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON persons " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON persons"
    )
  end
end
