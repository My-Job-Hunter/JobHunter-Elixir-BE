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

  `/inbound/email` (the provider's webhook, PLAN §15.1) joins here in P9.
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Defines `:jh_shared` (no-store) and `:jh_authenticated`, the latter
  # unused here: no route at the root is signed in.
  ApiShared.Routes.shared_pipelines()

  # **The deploy pipeline's health check, and the only unversioned route**
  # (copied from AutoCare, whose Jenkins step curls `$SITE/info` on every
  # backend it deploys). Serving it at the root keeps that step identical for
  # all of them; a per-app path would put every pipeline in the blast radius
  # of a change here.
  #
  # Unauthenticated for the same reason the controller says: "which build is
  # on staging?" has to be answerable before you can sign in. `:jh_shared`
  # because an answer that names a build must not be a proxy's cached one.
  scope "/", Api do
    pipe_through [:api, :jh_shared]

    get "/info", InfoController, :show
  end

  # **The dev mailbox** (JH-01 §3): every mail a dev build sends lands in
  # Swoosh's in-memory mailbox, read here. Compiled in only when
  # `config :api, dev_routes: true` (dev.exs), so a release has no such route.
  if Application.compile_env(:api, :dev_routes, false) do
    scope "/dev" do
      pipe_through [:jh_shared]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
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
