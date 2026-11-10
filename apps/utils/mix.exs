defmodule Utils.MixProject do
  use Mix.Project

  def project do
    [
      app: :utils,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Umbrella children do not inherit the root setting.
      elixirc_options: [warnings_as_errors: true],
      # Unit tests sit beside the code they test — `foo.ex` / `foo.test.exs`.
      # `test/support` still holds the cases and fixtures.
      test_paths: ["test", "lib"],
      test_pattern: "*.test.exs",
      test_load_filters: [&String.ends_with?(&1, ".test.exs")],
      test_coverage: [tool: ExCoveralls],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # **Every third-party dependency in the umbrella lives here**, and no other
  # app declares one (`Core.ConventionsTest` holds it).
  #
  # The hub has to be the app everything else already depends on, and the
  # dependency direction is `utils ← data ← core ← api_shared ← api_* ← api`.
  # Putting them in `core` would mean `data` depending on `core`, which is the
  # one direction the compiler is there to refuse. One list is one version.
  #
  # `utils` stays pure in its **code** — it names none of these. It carries
  # them so the apps above it do not each carry their own idea of the version.
  defp deps do
    [
      # ── The web layer ───────────────────────────────────────────────────
      {:phoenix, "~> 1.8.9"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      # The browser calls this API from a different origin than it serves the
      # app from, so every JSON request is preceded by a preflight `OPTIONS`.
      {:cors_plug, "~> 3.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # ── Storage ─────────────────────────────────────────────────────────
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      # UUIDv7 keys: they sort by creation time, so inserts stay local to the
      # end of the index where v4's random order scatters them.
      {:uniq, "~> 0.6.3"},

      # ── Auth ────────────────────────────────────────────────────────────
      {:bcrypt_elixir, "~> 3.1"},
      {:guardian, "~> 2.3"},
      # JWT revocation store — tracks issued tokens and supports revoke_all.
      {:guardian_db, "~> 3.0"},

      # ── Jobs, limits, time ──────────────────────────────────────────────
      {:oban, "~> 2.18"},
      {:hammer, "~> 7.4"},
      # `config :elixir, :time_zone_database` needs this. Without it every
      # DST-safe calculation returns an error for any zone but UTC.
      {:tz, "~> 0.28"},

      # ── Notifications ───────────────────────────────────────────────────
      {:swoosh, "~> 1.16"},
      # Swoosh's SMTP and SES adapters build the message with it.
      {:gen_smtp, "~> 1.2"},

      # ── The rest ────────────────────────────────────────────────────────
      {:jason, "~> 1.4"},
      # Money never touches a float.
      {:decimal, "~> 3.1"},
      # The house HTTP client — never httpoison, tesla or httpc.
      {:req, "~> 0.5"},

      # ── Tooling, shared by every app ────────────────────────────────────
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
