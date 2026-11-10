import Config

config :data, Data.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("JH_DB_PORT", "5432")),
  # A second dev backend (its own database) for a session that must not touch
  # the running one.
  database: System.get_env("JH_DB_NAME", "job_hunter_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# 4100 is clear of AutoCare's 4001 and 5720–5729 (PLAN §15.1), so both run at
# once. Loopback only: change `ip` to `{0, 0, 0, 0}` to reach it from another
# machine.
config :api, Api.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("JH_PORT", "4100"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0BYpcbyrJZmzV+FXYdkZs30eMWgC4s8YRjADWoXWsdaFIwLnNS4O+NBQMPenFyDL",
  watchers: []

# The Vite dev servers: the team console on 5800, the customer portal on 5801.
# **Both spellings**, because `localhost` and `127.0.0.1` are different origins
# to a browser and people type either.
config :api,
  cors_origins: [
    "http://localhost:5800",
    "http://127.0.0.1:5800",
    "http://localhost:5801",
    "http://127.0.0.1:5801"
  ]

# Mail is kept in the local in-memory mailbox rather than sent; read it at
# http://localhost:4100/dev/mailbox (`Api.Router`, dev only).
config :notifire, Notifire.Mailer, adapter: Swoosh.Adapters.Local
config :api, dev_routes: true

# Google's dev stand-in: `POST /auth/google {id_token: "dev:<email>"}` signs
# in an account that already has the address. On until GOOGLE_CLIENT_ID is set.
config :core, :google, stand_in: true

# Do not include metadata nor timestamps in development logs.
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such in
# production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation.
config :phoenix, :plug_init_mode, :runtime
