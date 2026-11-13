import Config

# Read when the release boots, so one build serves every environment; the
# environment is the only difference. Only what a server must decide is a
# variable: sample.env lists them. Required ones raise at boot, naming the
# variable.

# Google sign-in. Unset: no real Google, and in dev the stand-in stays on.
if google_client_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :core, :google, client_id: google_client_id
end

# Where the mails' links open, when the apps are not on localhost.
if console_url = System.get_env("CONSOLE_URL") do
  portal_url = System.get_env("PORTAL_URL", console_url)
  config :core, :app_urls, console: console_url, portal: portal_url
  config :notifire, :app_urls, console: console_url, portal: portal_url
end

# Web Push (AQ-08 §7.6): a server with a VAPID pair sends push; one without
# sends none, and the screens say "Push isn't set up on this server."
if vapid_private = System.get_env("VAPID_PRIVATE_KEY") do
  config :notifire, :web_push,
    public_key: System.fetch_env!("VAPID_PUBLIC_KEY"),
    private_key: vapid_private,
    subject: System.get_env("VAPID_SUBJECT", "mailto:support@autoqare.com")
end

# Forwarded mail (AQ-09 §6, §11.4): the address with `{token}` (Postmark's
# own `<hash>+{token}@inbound.postmarkapp.com` until P13's domain), and the
# webhook's basic-auth pair. Without a password the webhook answers 503.
if inbound_address = System.get_env("INBOUND_ADDRESS") do
  unless String.contains?(inbound_address, "{token}"),
    do: raise("INBOUND_ADDRESS must hold {token}, e.g. in+{token}@in.autoqare.com")

  config :core, :inbound, address: inbound_address
end

if inbound_password = System.get_env("INBOUND_PASSWORD") do
  config :core, :inbound,
    user: System.get_env("INBOUND_USER", "postmark"),
    password: inbound_password
end

if config_env() == :prod do
  # Never the stand-in in a release.
  config :core, :google, stand_in: false

  require_env = fn name, hint ->
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _missing ->
        raise """

        Environment variable #{name} is missing (or empty).

        #{hint}

        See sample.env in the repository root for the full list.
        """
    end
  end

  # Phoenix wants >= 64 bytes for the key base, and Guardian signs with HS512.
  require_secret = fn name, hint ->
    value = require_env.(name, hint)

    if byte_size(value) < 64 do
      raise """

      Environment variable #{name} is too short (#{byte_size(value)} bytes, needs >= 64).

      Generate one with:  mix phx.gen.secret
      """
    end

    value
  end

  get_int = fn name, default ->
    case Integer.parse(System.get_env(name) || to_string(default)) do
      {int, ""} ->
        int

      _invalid ->
        raise "Environment variable #{name} must be an integer, got: #{System.get_env(name)}"
    end
  end

  config :data, Data.Repo,
    url:
      require_env.(
        "DATABASE_URL",
        "e.g. ecto://USER:PASS@HOST:5432/autoqare_prod"
      ),
    show_sensitive_data_on_connection_error: false,
    pool_size: get_int.("POOL_SIZE", 10)

  # The apps that may call the API — and open its socket. An allowlist, never `*`.
  cors_origins =
    "CORS_ORIGINS"
    |> require_env.("""
    The apps' origins, comma-separated — the team console and the customer portal:

        CORS_ORIGINS=https://team.autoqare.com,https://autoqare.com
    """)
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :api, cors_origins: cors_origins

  config :api, Api.Endpoint,
    # A release serves nothing without it.
    server: true,
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: get_int.("PORT", 4100)
    ],
    check_origin: cors_origins,
    secret_key_base:
      require_secret.(
        "SECRET_KEY_BASE",
        "Signs Phoenix's tokens. Generate: mix phx.gen.secret"
      )

  # config.exs ships a dev secret; a release must never sign with it.
  config :core, Core.Auth.Guardian,
    secret_key:
      require_secret.(
        "GUARDIAN_SECRET_KEY",
        "Signs auth tokens. MUST differ from SECRET_KEY_BASE. Generate: mix phx.gen.secret"
      )

  # Uploaded bytes live on persistent storage outside the release directory.
  config :core, :storage,
    root:
      require_env.(
        "UPLOADS_ROOT",
        "A directory on persistent storage, outside the release directory, owned by the user this runs as."
      )

  if from_email = System.get_env("MAILER_FROM_EMAIL") do
    config :notifire, from_email: from_email
  end

  log_level = System.get_env("LOG_LEVEL", "info")

  if log_level not in ~w(emergency alert critical error warning notice info debug) do
    raise "LOG_LEVEL=#{inspect(log_level)} is not a Logger level."
  end

  config :logger, level: String.to_existing_atom(log_level)
end
