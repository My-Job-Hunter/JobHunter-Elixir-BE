defmodule Data.Schema do
  @moduledoc """
  The house schema defaults, in one place.

  **One style for every table** (PLAN §2.2: AutoCare runs two side by side; we
  keep one):

  - UUIDv7 primary keys, made by the application through `uniq`. They sort by
    creation time, so inserts stay at the end of the index where v4's random
    order scatters them. The column is a plain `uuid`, so foreign keys to it
    are ordinary `uuid` columns too.
  - `:utc_datetime_usec` timestamps, stored as `timestamptz`
    (`config :data, Data.Repo, migration_timestamps: [type: :timestamptz]`).

  Putting them here means a new schema cannot quietly get integer ids or a
  naive timestamp by forgetting two lines:

      defmodule Data.Leads.Lead do
        use Data.Schema

        schema "leads" do
          timestamps()
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, Uniq.UUID, version: 7, autogenerate: true, type: :uuid}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
