defmodule Api.Endpoint do
  @moduledoc """
  The one endpoint, on 4100 (PLAN §15.1), copied from AutoCare's.

  Three frontends call it from other origins — the team console (5800), the
  customer portal (5801) and, from P8, the extension — so `CORSPlug` sits
  **before the router**: a preflight never reaches a route. The websocket is
  `/socket`; `Api.UserSocket` refuses every connection until P1 brings auth.

  ## What AutoCare's endpoint has and this one does not

  - **No `Plug.Static`.** This is a JSON API with no `priv/static`: there are
    no assets, no favicon and no `robots.txt` to serve, and a static plug in
    front of an API is one more place a path can answer something other than
    the contract.
  - **No `Plug.Session`.** Auth is a bearer token in a header (`Core.Auth.Guardian`),
    so no response sets a cookie and no request carries one. A signed cookie
    session on a JSON API would be a second credential nobody reads, with a
    `signing_salt` to rotate for nothing.
  """

  use Phoenix.Endpoint, otp_app: :api

  # The client connects to `${SOCKET_URL}/socket`; websocket only, since every
  # browser we target has it and longpoll doubles the surface.
  socket "/socket", Api.UserSocket,
    websocket: true,
    longpoll: false

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  # **Before the router**, because a preflight never reaches a route.
  #
  # The console and the portal are served from other origins (5800 and 5801 →
  # 4100 in dev, and their own hostnames in production), so every request
  # carrying `content-type: application/json` or an `authorization` header is
  # preceded by an `OPTIONS`. Without this the router answers
  # `no route found for OPTIONS /team/v1/…` and **nothing works from a browser
  # at all** — which curl never shows you, because curl does not preflight.
  plug CORSPlug,
    # A 0-arity function rather than a literal list: `plug` options are read
    # at **compile** time, and the allowlist comes from `runtime.exs` on a
    # deployed box. A literal here would bake in whatever was configured when
    # the release was built.
    origin: &__MODULE__.cors_origins/0,
    headers: ["authorization", "content-type", "accept"],
    # A cross-origin response only exposes six headers by default and
    # `retry-after` is not one of them. Without this the 429 that tells
    # somebody *when they can post again* arrives with its number stripped,
    # and the client's `retryAfterSeconds` is silently `nil`.
    expose: ["retry-after"],
    max_age: 86_400

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Api.Router

  @doc """
  Who may call this API from a browser.

  **An allowlist, never `*`.** These requests carry a bearer token, and an API
  that accepts any origin lets any page on the internet make authenticated
  calls with a token it has tricked out of a user.

  Empty by default rather than permissive: `runtime.exs` refuses to boot
  production without `CORS_ORIGINS`, so the failure is a clear one at start-up
  instead of a silent hole.
  """
  def cors_origins, do: Application.get_env(:api, :cors_origins, [])
end
