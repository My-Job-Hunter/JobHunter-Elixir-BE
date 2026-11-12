defmodule Autoqare.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      # Set here *and* in every app: umbrella children do not inherit it, so
      # the root setting alone silently protects nothing.
      elixirc_options: [warnings_as_errors: true],
      deps: deps(),
      aliases: aliases(),
      # Phoenix 1.8 + Mix 1.20 reload through a Mix listener. Without it every
      # request in `iex -S mix phx.server` prints "a Mix listener expected by
      # Phoenix.CodeReloader is missing" and the reloader does nothing.
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        # `:cors_plug` because `Api.Endpoint` names `CORSPlug`, and `:credo`
        # because `apps/core/lib/credo/checks/max_file_length.ex` is a custom
        # check built on its behaviour.
        plt_add_apps: [:mix, :ex_unit, :cors_plug, :credo],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # `precommit` ends in `test`, so it has to run in the test environment —
  # otherwise Mix refuses with "mix test is running in the dev environment".
  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Available only to the umbrella root, not to the apps. Every other
  # third-party dependency lives in `apps/utils/mix.exs`.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # The same gates CI runs, in the same order, so a green local run means a
  # green pipeline. `mix precommit` is the only command anyone needs to learn.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      # `--quiet` on create, not on migrate: the migration stack is the one
      # moment you want to watch, because it is where a migration fails.
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate"] ++ seeds(),
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # An empty database with the production seed alone: what a deployment's
      # database looks like before anyone arrives.
      "ecto.reset.clean": ["ecto.drop", "ecto.create --quiet", "ecto.migrate", "aq.prod_seed"],
      # Just the data, on a database that already exists.
      "ecto.seed": seeds(),
      # `data` starts the Repo, so a test run needs the database to exist.
      # **`aq.seed_reference` belongs to preparing the database**, not to
      # seeding demo data: reference lists are closer to the schema than to
      # content, and a suite that depends on someone having run `ecto.reset`
      # by hand fails for the next person to clone.
      test: [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "aq.seed_reference",
        "test"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  # **The suite's database is empty because nothing seeds it**, not because a
  # seed checks where it is. Only the reference lists load under
  # `MIX_ENV=test`.
  #
  # Outside test, a dev database holds what a deployment holds (the production
  # seed, which starts with the reference groups and is idempotent) and then
  # the dev-only rows. Add a new seed task here, never to the aliases directly.
  #
  # `aq.seed_standard` is last: the standard test set (`Core.Standard`,
  # docs/TEST-ACCOUNTS.md), made through the front door, so it needs the
  # production seed first. It lives in `core` and does nothing outside dev.
  defp seeds do
    ["aq.seed_reference"] ++
      if Mix.env() == :test,
        do: [],
        else: ["aq.prod_seed", "aq.seed_demo", "aq.seed_standard"]
  end
end
