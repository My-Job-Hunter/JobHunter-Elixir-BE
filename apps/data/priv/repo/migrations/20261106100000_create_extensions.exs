defmodule Data.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  @moduledoc """
  The Postgres extensions the data model uses (PLAN §2.2), first, so every
  later migration can rely on them.

  | Extension | For |
  |---|---|
  | `citext` | emails and handles, unique without anyone remembering to downcase |
  | `pg_trgm` | fuzzy search: similar job titles, company names |
  | `unaccent` | search that matches *cafe* to *café* |
  | `btree_gist` | exclusion constraints, e.g. two meetings for one person at once |
  | `pgcrypto` | token digests |

  **PostGIS is not here** (AutoCare has it): nothing in Job Hunter is a place
  on a map until a phase proves otherwise.

  All five are trusted or contrib extensions a dev and test superuser can
  create; `IF NOT EXISTS` makes this a no-op on a server whose administrator
  created them first.
  """

  @extensions ~w(citext pg_trgm unaccent btree_gist pgcrypto)

  def change do
    for extension <- @extensions do
      execute(
        "CREATE EXTENSION IF NOT EXISTS #{extension}",
        "DROP EXTENSION IF EXISTS #{extension}"
      )
    end
  end
end
