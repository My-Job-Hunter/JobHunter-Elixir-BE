defmodule ApiExt.Router do
  @moduledoc """
  The API for the Chrome extension (AQ-05 §11.1): a BD member on LinkedIn
  or Upwork. `Api.Endpoint` forwards `/ext` here, so `/v1/…` below is
  `/ext/v1/…` to a client.

  **On device tokens only** (QP5-5): `POST /v1/session` exchanges the
  console's one-time code for a device and its Guardian pair, and is the
  one route without a token; every other route needs a token whose
  `dev.app` is `ext` (`ApiShared.Plugs.TokenApp`), of a live device of a
  live staff account (`ApiExt.Plugs.Device`), and acts `via: :extension`.
  A console or portal token is `401` here, and a device token is `401` on
  `/team` and `/client`.

  From the shared set it mounts only `/info`, `auth/refresh`, `auth/logout`
  (which disconnects the device), `GET /me` and the bell
  (`ApiShared.Routes.extension_routes/1`): nobody signs in inside the
  extension. Rate limits (§11.4): 120 requests a minute per device; the
  exchange 10 a minute per address.
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
    plug ApiShared.Plugs.App, "ext"
  end

  ApiShared.Routes.shared_pipelines()

  # After `:aq_authenticated`: the live device the token names.
  pipeline :aq_device do
    plug ApiExt.Plugs.Device
  end

  pipeline :aq_device_limit do
    plug Core.Plugs.RateLimit, name: "ext_device", limit: 120, scale_ms: 60_000, by: :device
  end

  pipeline :aq_session_limit do
    plug Core.Plugs.RateLimit, name: "ext_session", limit: 10, scale_ms: 60_000
  end

  # `:aq_shared` puts `cache-control: no-store` on every answer: these carry
  # tokens and people's work.
  scope "/v1" do
    pipe_through [:api, :aq_shared]

    scope "/", ApiExt do
      pipe_through :aq_session_limit
      post "/session", SessionController, :create
    end

    ApiShared.Routes.extension_routes([:aq_device, :aq_device_limit])

    scope "/", ApiExt do
      pipe_through [:aq_authenticated, :aq_device, :aq_device_limit]

      delete "/session", SessionController, :delete
      get "/context", ContextController, :show
      get "/config", ConfigController, :show

      get "/jobs/lookup", JobController, :lookup
      post "/jobs/capture", JobController, :capture

      post "/leads/save", LeadController, :save
      post "/leads/applied", LeadController, :applied
      post "/leads/:id/apply-again", LeadController, :apply_again

      post "/health", HealthController, :create

      # AQ-06 §9 (v1b): a LinkedIn thread or an Upwork room.
      post "/conversations/capture", ConversationController, :capture

      # AQ-08 §7.5: the minute poll claims the person's pop-ups.
      get "/notifications/pop-ups", NotificationController, :pop_ups
    end
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
