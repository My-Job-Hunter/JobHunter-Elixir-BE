defmodule ApiTeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :api_team,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Umbrella children do not inherit the root setting.
      elixirc_options: [warnings_as_errors: true],
      # Unit tests sit beside the code they test, as in every app here.
      test_paths: ["test", "lib"],
      test_pattern: "*.test.exs",
      test_load_filters: [&String.ends_with?(&1, ".test.exs")],
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls],
      deps: deps()
    ]
  end

  # The API for the team console (5800), mounted at `/team`.
  # A library of routes and controllers: it starts no processes, and the one
  # endpoint, `Api.Endpoint`, serves it.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # In-umbrella only. Third-party deps live in `utils`. Never `api`: the
  # endpoint sits on top of every API app.
  #
  # `notifire` for the dev routes alone (AQ-08 §11.3): `POST /dev/sweeps`
  # runs the delivery sweep and answers its counts, and `/dev/push/json`
  # reads the push outbox. An API app may call `notifire`; `core` never.
  defp deps do
    [
      {:api_shared, in_umbrella: true},
      {:core, in_umbrella: true},
      {:notifire, in_umbrella: true},
      {:utils, in_umbrella: true}
    ]
  end
end
