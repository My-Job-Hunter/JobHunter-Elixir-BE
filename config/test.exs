import Config

# The MIX_TEST_PARTITION environment variable can be used to provide built-in
# test partitioning in CI environment. Run `mix help test` for more
# information.
config :data, Data.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("JH_DB_PORT", "5432")),
  database: "job_hunter_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test.
config :api, Api.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base: "GVL9wQcNuWZB4P0olqJSnSNvbZHK0JLAzMmrn5yMKCACwr5hPlpeUKbJkOCP/j7/",
  server: false

# Only warnings and errors during tests — the query log buries a real failure
# under a hundred lines of SELECT.
config :logger, level: :warning

# Speed up the test suite: bcrypt's cost is a security control in production
# and pure latency here.
config :bcrypt_elixir, log_rounds: 4

config :core, Core.Auth.Guardian,
  secret_key: "test-only-secret-not-used-anywhere-else-0123456789abcdefghijkl"

# Oban stays inert in tests: a background job racing the SQL sandbox produces
# failures that have nothing to do with the code under test. Workers are
# tested by calling them (`perform_job/2`) or the function they delegate to.
config :core, Oban, testing: :manual

# Nothing leaves the machine, and `assert_email_sent` works off the mailbox.
config :notifire, Notifire.Mailer, adapter: Swoosh.Adapters.Test

# The token sweeper deletes expired `guardian_tokens` on a timer. Under the
# SQL sandbox it would run from a process no case checked out a connection
# for, so it would raise rather than sweep.
config :core, start_token_sweeper: false

# A temp directory, so a test run never writes into the repo; caps small
# enough that the too-large test does not have to build five megabytes.
config :core, :storage,
  adapter: Core.Storage.Local,
  root: Path.join(System.tmp_dir!(), "job-hunter-test-uploads"),
  max_bytes: [photo: 5_000, document: 12_000, attachment: 12_000]

# Google against the tests' own keys (`Core.Auth.GoogleTestKeys`); the
# stand-in is tested by switching it on for one test.
config :core, :google,
  client_id: "test-client.apps.googleusercontent.com",
  stand_in: false,
  keys: Core.Auth.GoogleTestKeys

# Rate limiting is off by default in tests: a suite that hammers an endpoint
# is the point of the suite. `Core.Plugs.RateLimitTest` turns it on and
# asserts it bites.
config :core, Core.Plugs.RateLimit, enabled: false

# A fixed allowlist, so the CORS tests assert on a value rather than on
# whatever dev happens to be set to.
config :api, cors_origins: ["http://localhost:5800", "http://localhost:5801"]

# Initialize plugs at runtime for faster test compilation.
config :phoenix, :plug_init_mode, :runtime
