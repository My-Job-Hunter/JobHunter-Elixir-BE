# This file is responsible for configuring your umbrella and **all
# applications** and their dependencies with the help of the Config module.
#
# All applications in the umbrella share the same configuration and
# dependencies, which is why they all use the same configuration file.
import Config

# **Configured before the first schedule is written.** Without it
# `DateTime.from_naive/2` returns `{:error, :utc_only_time_zone_database}` for
# every real zone, which is invisible while the tests only ever use Etc/UTC.
#
# `tz` rather than `tzdata`: `tz` ships the database compiled in and needs no
# HTTP client at runtime, so hackney never enters the tree.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :data,
  ecto_repos: [Data.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

# **One key style and one time type, for every table** (PLAN §2.2). A
# `create table(:x)` gets a `uuid` key with no default (the application makes
# UUIDv7 keys, `Data.Schema`), and `timestamps()` in a migration is
# `timestamptz` — never `timestamp without time zone`.
config :data, Data.Repo,
  migration_primary_key: [type: :uuid],
  migration_foreign_key: [type: :uuid],
  migration_timestamps: [type: :timestamptz]

# Queues are named by purpose with deliberate concurrency, never one
# `default: 10` (PLAN §15.7). `scheduling` is separate so reminders never wait
# behind a long email batch; `ai` sits at 2 because those calls are slow and
# rate-limited upstream, so more concurrency buys nothing but a bill.
config :core, Oban,
  repo: Data.Repo,
  queues: [
    scheduling: 5,
    retention: 2,
    notifications: 10,
    emails: 5,
    push: 5,
    ingest: 5,
    behaviour: 2,
    ai: 2
  ],
  plugins: [
    # Oban's own housekeeping: completed jobs are pruned after a week.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Workers owned by `notifire` are named here, never in `core`'s code:
    # config is not a dependency, which is what keeps the two siblings apart.
    # The media sweep (JH-01 §4.1): abandoned uploads older than a day, daily.
    {Oban.Plugins.Cron, crontab: [{"20 3 * * *", Core.Media.SweepWorker}]}
  ]

# **Broadcasts go through the endpoint, not through PubSub by hand.**
# Injected rather than named, because `api` depends on `core` and never the
# other way round. Same shape as the Guardian user loader below.
config :core, :endpoint, Api.Endpoint

# The user loader is injected so `core` does not compile-depend on a context.
# `Core.Accounts.load_user/1` answers `{:error, :not_found}` for an unknown,
# suspended or deactivated account, so a token it holds stops working.
config :core, Core.Auth.Guardian,
  issuer: "job_hunter",
  user_loader: {Core.Accounts, :load_user},
  # Overridden in runtime.exs for prod — never ship this value.
  secret_key: "dev-only-secret-replace-in-runtime-exs-CHANGE-ME-0123456789abcdef"

# The revocation store (`guardian_tokens`). `Guardian.DB.Sweeper` runs under
# `Core.Application` and deletes expired rows every `sweep_interval` minutes.
config :guardian, Guardian.DB,
  repo: Data.Repo,
  schema_name: "guardian_tokens",
  sweep_interval: 60

# **The mail seam** (CONVENTIONS §7): `core` enqueues a job naming a
# `notifire` worker read from here, never from code. Config is not a
# dependency, which is what keeps the two siblings apart.
config :core, :mail_workers,
  invitation: Notifire.Workers.InvitationWorker,
  password_reset: Notifire.Workers.PasswordResetWorker,
  email_change: Notifire.Workers.EmailChangeWorker

# Where the links in the mails open: the console and the portal. Both apps
# read them (`core` for the bootstrap's printed link, `notifire` for the
# mails), so they sit under both keys from one place.
app_urls = [console: "http://localhost:5800", portal: "http://localhost:5801"]
config :core, :app_urls, app_urls
config :notifire, :app_urls, app_urls
config :notifire, from_name: "Job Hunter", from_email: "hello@jobhunter.local"

# *Continue with Google* (QP1-5). No client id until the owner creates one;
# until then a dev build uses the stand-in (dev.exs: `id_token = "dev:<email>"`).
# runtime.exs reads GOOGLE_CLIENT_ID and turns the stand-in off in prod.
config :core, :google,
  client_id: nil,
  stand_in: false,
  keys: Core.Auth.Google.Keys.Google

# Uploaded bytes (`Core.Storage`): a folder on this box, outside anything a
# static plug could serve. The caps are QP1-3's: 5 MB for a photo, 10 MB for
# a document or attachment, read by both halves of the upload.
config :core, :storage,
  adapter: Core.Storage.Local,
  root: Path.expand("../priv/uploads", __DIR__),
  max_bytes: [photo: 5_000_000, document: 10_000_000, attachment: 10_000_000]

# Swoosh boots with hackney by default and raises without it. Req is the
# house HTTP client and hackney is deliberately absent.
config :swoosh, :api_client, Swoosh.ApiClient.Req

config :api,
  generators: [context_app: false]

config :api, Api.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # Errors Phoenix raises itself (a crash, a malformed body) render in the
  # house shape too.
  render_errors: [
    formats: [json: ApiShared.ErrorJSON],
    layout: false
  ],
  # Owned by core, which is where the channels will be.
  pubsub_server: Core.PubSub

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom of this
# file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
