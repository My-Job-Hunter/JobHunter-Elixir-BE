defmodule Data.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  @moduledoc """
  Oban's own tables (`oban_jobs`, `oban_peers`), from its migration module.

  Versioned rather than copied, as mCart does: `Oban.Migration` knows how
  to move between its own schema versions, which a hand-written copy would
  not. Oban 2.24's current version is 14.
  """

  def up, do: Oban.Migration.up(version: 14)

  # Back to nothing, so a rollback undoes exactly what this did.
  def down, do: Oban.Migration.down(version: 1)
end
