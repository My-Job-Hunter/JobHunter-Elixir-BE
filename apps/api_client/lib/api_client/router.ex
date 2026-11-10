defmodule ApiClient.Router do
  @moduledoc """
  The API for the customer portal (5801): the customer, and only their own
  rows. `Api.Endpoint` forwards `/client` here, so `/v1/…` below is
  `/client/v1/…` to a client.

  It includes the shared routes (`ApiShared.Routes`: `/info`, `/auth/*`,
  `/me/*`, `/media/*`) and adds the portal's own (JH-01 §6.3): the
  customer's record, profiles, channels, documents and "who serves me".

  **Isolation by construction** (PLAN §0): every route here runs behind
  `:jh_customer`, which pins the scope to the signed-in customer
  (`ApiClient.Plugs.CustomerScope`) and refuses a staff account with
  `not_a_customer`. No route takes a customer id, so none exists that could
  reach another customer's rows.
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
    plug ApiShared.Plugs.App, "client"
  end

  ApiShared.Routes.shared_pipelines()

  # After `:jh_authenticated`: the scope, pinned to the customer.
  pipeline :jh_customer do
    plug ApiClient.Plugs.CustomerScope
  end

  # `:jh_shared` puts `cache-control: no-store` on every answer: a version
  # from a proxy is the wrong version, and these carry tokens.
  scope "/v1" do
    pipe_through [:api, :jh_shared]

    ApiShared.Routes.shared_routes()

    scope "/", ApiClient do
      pipe_through [:jh_authenticated, :jh_customer]

      get "/customer", CustomerController, :show
      patch "/customer", CustomerController, :update
      get "/team", CustomerController, :team

      get "/profiles", ProfileController, :index
      get "/profiles/:id", ProfileController, :show
      patch "/profiles/:id", ProfileController, :update
      put "/profiles/:id/skills", ProfileController, :put_skills
      put "/profiles/:id/channels", ProfileController, :put_channels

      get "/channels", ChannelController, :index
      post "/channels", ChannelController, :create
      patch "/channels/:id", ChannelController, :update
      post "/channels/:id/archive", ChannelController, :archive

      get "/profiles/:id/documents", DocumentController, :index
      post "/profiles/:id/documents", DocumentController, :create
      put "/profiles/:id/default-document", DocumentController, :put_default
      post "/documents/:id/new-version", DocumentController, :new_version
      post "/documents/:id/archive", DocumentController, :archive

      get "/skills", SkillController, :index
    end
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
