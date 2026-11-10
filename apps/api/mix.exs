defmodule Api.MixProject do
  use Mix.Project

  def project do
    [
      app: :api,
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
      # `test/support` still holds the cases.
      test_paths: ["test", "lib"],
      test_pattern: "*.test.exs",
      test_load_filters: [&String.ends_with?(&1, ".test.exs")],
      test_coverage: [tool: ExCoveralls],
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Api.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Third-party deps live in `utils`, the umbrella's dependency hub — see
  # `apps/utils/mix.exs`. Nothing else declares one.
  #
  # Transport only. `api` may reach every app below it; nothing reaches back,
  # which is what makes the boundary a compile error rather than a review
  # comment.
  defp deps do
    [
      # The routers `Api.Router` forwards to. Each depends on `api_shared`,
      # never on `api`: the endpoint sits on top of them all.
      {:api_team, in_umbrella: true},
      {:api_client, in_umbrella: true},
      {:api_ext, in_umbrella: true},
      {:api_shared, in_umbrella: true},
      {:core, in_umbrella: true},
      {:data, in_umbrella: true},
      {:utils, in_umbrella: true}
    ]
  end
end
