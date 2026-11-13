defmodule Api.Router do
  @moduledoc """
  The one endpoint's router. It forwards each app's prefix to that app's own
  router (PLAN §15.1):

  | Prefix | Router | App |
  |---|---|---|
  | `/team` | `ApiTeam.Router` | the team console (5800) |
  | `/client` | `ApiClient.Router` | the customer portal (5801) |
  | `/ext` | `ApiExt.Router` | the Chrome extension (P8) |

  Each of those serves its own `/v1/…`, so a version sits in every client
  path and the server can move while an old extension build keeps working.

  **`GET /info` at the root is the one unversioned route**, and it is not a
  client route; the scope below carries the reason. Anything else answers
  `404` in the house error shape.

  **`POST /inbound/email`** (AQ-09 §6.2, PLAN §15.1) is the mail
  provider's webhook, at the root and outside the three apps: no app's
  token reaches it, basic auth does (`Api.InboundController`). Its body
  may be 30 MB, on that route alone (`Api.Endpoint.parse/2`).
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Defines `:aq_shared` (no-store) and `:aq_authenticated`, the latter
  # used only by the dev clock's routes (dev servers alone).
  ApiShared.Routes.shared_pipelines()

  # **The deploy pipeline's health check, and the only unversioned route**
  # (copied from mCart, whose Jenkins step curls `$SITE/info` on every
  # backend it deploys). Serving it at the root keeps that step identical for
  # all of them; a per-app path would put every pipeline in the blast radius
  # of a change here.
  #
  # Unauthenticated for the same reason the controller says: "which build is
  # on staging?" has to be answerable before you can sign in. `:aq_shared`
  # because an answer that names a build must not be a proxy's cached one.
  scope "/", Api do
    pipe_through [:api, :aq_shared]

    get "/info", InfoController, :show
  end

  # **Forwarded mail** (AQ-09 §6.2): the provider posts each delivery here
  # with the basic-auth pair in its URL. No app token, no session.
  scope "/inbound", Api do
    pipe_through [:api, :aq_shared]

    post "/email", InboundController, :email
  end

  # **The dev mailbox** (AQ-01 §3): every mail a dev build sends lands in
  # Swoosh's in-memory mailbox, read here. Compiled in only when
  # `config :api, dev_routes: true` (dev.exs), so a release has no such route.
  if Application.compile_env(:api, :dev_routes, false) do
    scope "/dev" do
      pipe_through [:aq_shared]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # **A forwarded mail by hand** (AQ-09 §6.3): `{to, eml}` through the
    # webhook's own intake, `provider: dev`.
    scope "/dev", Api do
      pipe_through [:api, :aq_shared]

      post "/inbound", InboundController, :dev
    end

    # **The push outbox** (AQ-08 QP8-16), beside the mailbox: every push a
    # dev server sends, kept for a script to read, and emptied.
    scope "/dev", ApiTeam do
      pipe_through [:api, :aq_shared]

      get "/push/json", DevController, :push_outbox
      delete "/push/json", DevController, :clear_push_outbox
    end

    # **The dev clock** (AQ-04B §7.6, QP4b-1): any signed-in account moves
    # the whole server's *now*, or runs the sweeps now. Here and nowhere
    # else, so a release has neither route.
    scope "/dev", ApiTeam do
      pipe_through [:api, :aq_shared, :aq_authenticated]

      get "/clock", DevController, :clock
      post "/clock", DevController, :set_clock
      post "/sweeps", DevController, :sweeps
    end
  end

  # **Each app's API, divided from day one.** Each prefix appears exactly once
  # in this file, so no forward can swallow a route defined elsewhere, and the
  # forwarded router answers its own unknown paths (`/team/v1/nope`).
  forward "/team", ApiTeam.Router
  forward "/client", ApiClient.Router
  forward "/ext", ApiExt.Router

  # Last: a path under no prefix answers `404` `not_found` in the same shape
  # the app routers use, rather than Phoenix's `NoRouteError` page.
  ApiShared.Routes.not_found_routes()
end
