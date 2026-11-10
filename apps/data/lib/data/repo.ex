defmodule Data.Repo do
  @moduledoc """
  The one Repo, owned by `data`.

  Every query in the system goes through here, and `data` is the only app that
  knows Postgres exists. `core` asks `data` for rows; the API apps render what
  `core` returns. That direction is enforced by the umbrella's dependency
  graph rather than by convention.
  """

  use Ecto.Repo,
    otp_app: :data,
    adapter: Ecto.Adapters.Postgres
end
