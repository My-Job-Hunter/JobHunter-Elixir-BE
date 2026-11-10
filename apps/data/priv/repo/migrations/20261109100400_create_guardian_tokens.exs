defmodule Data.Repo.Migrations.CreateGuardianTokens do
  use Ecto.Migration

  @moduledoc """
  `guardian_db`'s token store, in its own shape (JH-01 §4.1).

  What makes sign-out-everywhere and suspension actually revoke a token:
  without it a JWT stays valid until it expires whatever the server thinks.
  `Guardian.DB.Sweeper` (started by `Core.Application` from P1) deletes
  expired rows on a timer.

  **`timestamps(type: :naive_datetime)`, the one table not on `timestamptz`**:
  guardian_db's own schema writes `NaiveDateTime`s, which Postgrex refuses to
  put into a `timestamptz` column. The rows are the library's, never read by
  our code for their time. The trigger still attaches so the house rule
  holds for every table.
  """

  def change do
    create table(:guardian_tokens, primary_key: false) do
      add(:jti, :string, primary_key: true)
      add(:aud, :string, primary_key: true)
      add(:typ, :string)
      add(:iss, :string)
      add(:sub, :string)
      add(:exp, :bigint)
      add(:jwt, :text)
      add(:claims, :map)

      timestamps(type: :naive_datetime)
    end

    # The sweeper deletes expired rows on a schedule; without this it table-scans.
    create(index(:guardian_tokens, [:exp]))
    # "Revoke everything for this user" — the logout-everywhere query.
    create(index(:guardian_tokens, [:sub]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON guardian_tokens " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON guardian_tokens"
    )
  end
end
