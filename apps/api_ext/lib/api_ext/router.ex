defmodule ApiExt.Router do
  @moduledoc """
  The API for the Chrome extension: a BD member on LinkedIn or Upwork.
  `Api.Endpoint` forwards `/ext` here, so `/v1/…` below is `/ext/v1/…` to
  a client.

  It includes the shared routes (`ApiShared.Routes`): in P0, `GET /v1/info`,
  which answers `{"app": "ext", "api": "v1", "version": …}`. Anything else
  answers `404` `not_found` in the house error shape.

  The extension's session, capture and lookup routes arrive in P8 (PLAN
  §15.4), on device tokens.
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
    plug ApiShared.Plugs.App, "ext"
  end

  ApiShared.Routes.shared_pipelines()

  # `:jh_shared` puts `cache-control: no-store` on every answer: a version
  # from a proxy is the wrong version, and from P1 these carry tokens.
  scope "/v1" do
    pipe_through [:api, :jh_shared]

    ApiShared.Routes.shared_routes()
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
