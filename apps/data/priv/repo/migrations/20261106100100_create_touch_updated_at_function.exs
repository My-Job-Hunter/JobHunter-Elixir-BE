defmodule Data.Repo.Migrations.CreateTouchUpdatedAtFunction do
  use Ecto.Migration

  @moduledoc """
  `updated_at` moves on every update, whoever writes it: a row updated without
  setting it gets the moment of the update; a row whose update sets it keeps
  what was set (the code's clock, `Core.Clock`).

  **The function only.** No table exists yet, so there is nothing to attach it
  to. Every `create table` with `timestamps()` adds its own trigger in the same
  migration (`Core.ConventionsTest` holds it):

      execute(
        "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON leads " <>
          "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
        "DROP TRIGGER IF EXISTS touch_updated_at ON leads"
      )
  """

  def up do
    execute("""
    CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := now();
      END IF;
      RETURN NEW;
    END $$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS touch_updated_at()")
  end
end
