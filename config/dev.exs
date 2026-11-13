import Config

# LOCAL_IP (the workspace's .env, beside the three repos; the aq-backend launcher sources it): this
# Mac's address on the local network. Set, the backend listens on every address, the apps opened at
# that address may call it, and email and invitation links open there, so others on the network
# can test; empty, everything stays on localhost. mCart's way.
local_ip = String.trim(System.get_env("LOCAL_IP", ""))
dev_host = if local_ip == "", do: "localhost", else: local_ip

config :data, Data.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("AQ_DB_PORT", "5432")),
  # A second dev backend (its own database) for a session that must not touch
  # the running one.
  database: System.get_env("AQ_DB_NAME", "autoqare_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# 4100 is clear of mCart's 4001 and 5720–5729 (PLAN §15.1), so both run at
# once. Loopback only, unless LOCAL_IP is set (above).
config :api, Api.Endpoint,
  http: [
    ip: if(local_ip == "", do: {127, 0, 0, 1}, else: {0, 0, 0, 0}),
    port: String.to_integer(System.get_env("AQ_PORT", "4100"))
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0BYpcbyrJZmzV+FXYdkZs30eMWgC4s8YRjADWoXWsdaFIwLnNS4O+NBQMPenFyDL",
  watchers: []

# The Vite dev servers: the team console on 5800, the customer portal on 5801.
# **Both spellings**, because `localhost` and `127.0.0.1` are different origins
# to a browser and people type either.
config :api,
  cors_origins:
    [
      "http://localhost:5800",
      "http://127.0.0.1:5800",
      "http://localhost:5801",
      "http://127.0.0.1:5801"
    ] ++
      if(local_ip == "",
        do: [],
        else: Enum.map(~w(5800 5801), &"http://#{local_ip}:#{&1}")
      )

# Where email and invitation links open (config.exs says localhost): at LOCAL_IP when it is set.
app_urls = [console: "http://#{dev_host}:5800", portal: "http://#{dev_host}:5801"]
config :core, :app_urls, app_urls
config :notifire, :app_urls, app_urls

# Mail is kept in the local in-memory mailbox rather than sent; read it at
# http://localhost:4100/dev/mailbox (`Api.Router`, dev only).
config :notifire, Notifire.Mailer, adapter: Swoosh.Adapters.Local
config :api, dev_routes: true

# Web Push (AQ-08 §7.6, QP8-13): **a dev-only VAPID pair**, so a browser on
# localhost can turn push on. Never used anywhere else: a release reads
# VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY and VAPID_SUBJECT (runtime.exs) and
# sends no push without them. The push outbox (QP8-16) keeps a copy of each
# push for http://localhost:4100/dev/push/json, and the real push still goes.
config :notifire, :web_push,
  public_key:
    "BMJ2GZOUVpfwgiBKw8bqsPk-GDx7oezk_FrNx-3uakdmMaYpxuWzpimSu0kphhbAn1tz6w9wuq3npq0PF0WLyr0",
  private_key: "MR8DaC-SFnxwzyqrkolAAQcfNQpCdrN57N84yY3g20Y",
  subject: "mailto:support@autoqare.com"

config :notifire, push_outbox: true

# The dev clock (AQ-04B §7.6): `POST /dev/clock {days}` moves `Core.Clock.now/0`
# for the whole server. Only here; a release refuses to set it.
config :core, dev_clock: true

# The cast's shared test password is on the worst-list (the user's words of
# 2026-11-11: "set all the passwords for testing purpose to password123").
# Only here; test and a release keep the whole rule (`Core.Accounts.Password`).
config :core, dev_worst_passwords: true

# Forwarded mail's webhook (AQ-09 §6.2): a dev-only basic-auth pair, so
# `POST /inbound/email` can be tried on a dev server (and refused with a
# wrong one). A release reads INBOUND_USER and INBOUND_PASSWORD.
config :core, :inbound, user: "postmark", password: "inbound-dev"

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
