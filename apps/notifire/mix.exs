defmodule Notifire.MixProject do
  use Mix.Project

  def project do
    [
      app: :notifire,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Umbrella children do not inherit the root setting.
      elixirc_options: [warnings_as_errors: true],
      # Unit tests sit beside the code they test — `foo.ex` / `foo.test.exs`.
      test_paths: ["test", "lib"],
      test_pattern: "*.test.exs",
      test_load_filters: [&String.ends_with?(&1, ".test.exs")],
      test_coverage: [tool: ExCoveralls],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Notifire.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Third-party deps live in `utils`, the umbrella's dependency hub — see
  # `apps/utils/mix.exs`. Nothing else declares one.
  #
  # **No `core`.** They are siblings: `core` decides what to say and writes a
  # notification row, and this app delivers unsent rows. The table is the seam.
  defp deps do
    [
      {:data, in_umbrella: true},
      {:utils, in_umbrella: true}
    ]
  end
end
