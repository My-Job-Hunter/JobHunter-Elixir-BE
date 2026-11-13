defmodule ApiClient.Router do
  @moduledoc """
  The API for the customer portal (5801): the customer, and only their own
  rows. `Api.Endpoint` forwards `/client` here, so `/v1/…` below is
  `/client/v1/…` to a client.

  It includes the shared routes (`ApiShared.Routes`: `/info`, `/auth/*`,
  `/me/*`, `/media/*`) and adds the portal's own (AQ-01 §6.3): the
  customer's record, profiles, channels, documents and "who serves me";
  their board (AQ-02 §7.3); their applications (AQ-04A §8.2); and what
  waits on their approval (AQ-07 §11.2).

  **Isolation by construction** (PLAN §0): every route here runs behind
  `:aq_customer`, which pins the scope to the signed-in customer
  (`ApiClient.Plugs.CustomerScope`) and refuses a staff account with
  `not_a_customer`. No route takes a customer id, so none exists that could
  reach another customer's rows.
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    # `ics` for a meeting's calendar file (AQ-06 §8.2).
    plug :accepts, ["json", "ics"]
    plug ApiShared.Plugs.App, "client"
  end

  ApiShared.Routes.shared_pipelines()

  # After `:aq_authenticated`: the scope, pinned to the customer.
  pipeline :aq_customer do
    plug ApiClient.Plugs.CustomerScope
  end

  # `:aq_shared` puts `cache-control: no-store` on every answer: a version
  # from a proxy is the wrong version, and these carry tokens.
  scope "/v1" do
    pipe_through [:api, :aq_shared]

    ApiShared.Routes.shared_routes()

    scope "/", ApiClient do
      pipe_through [:aq_authenticated, :aq_customer]

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
      post "/channels/:id/inbound-address", ChannelController, :renew_address

      get "/profiles/:id/documents", DocumentController, :index
      post "/profiles/:id/documents", DocumentController, :create
      put "/profiles/:id/default-document", DocumentController, :put_default
      post "/documents/:id/new-version", DocumentController, :new_version
      post "/documents/:id/archive", DocumentController, :archive

      get "/skills", SkillController, :index

      # The customer's board (AQ-02 §7.3).
      get "/board", BoardController, :show
      post "/tasks", TaskController, :create
      get "/tasks/:id", TaskController, :show
      patch "/tasks/:id", TaskController, :update
      post "/tasks/:id/done", TaskController, :done
      post "/tasks/:id/reopen", TaskController, :reopen
      post "/tasks/:id/withdraw", TaskController, :withdraw
      post "/tasks/:id/checklist/:item_id/toggle", TaskController, :toggle_item
      post "/tasks/:id/steps/:step_id/toggle", TaskController, :toggle_step
      post "/tasks/:id/files", TaskController, :add_file
      get "/tasks/:id/history", TaskController, :history
      get "/tasks/:id/comments", TaskController, :comments
      post "/tasks/:id/comments", TaskController, :comment
      post "/tasks/:id/comments/:comment_id/replies", TaskController, :reply
      patch "/task-comments/:id", TaskController, :update_comment
      delete "/task-comments/:id", TaskController, :delete_comment
      patch "/task-replies/:id", TaskController, :update_reply
      delete "/task-replies/:id", TaskController, :delete_reply

      # My applications (AQ-04A §8.2).
      get "/leads", LeadController, :index
      get "/leads/:id", LeadController, :show
      post "/leads/:id/applied", LeadController, :applied
      get "/suggestions", LeadController, :suggestions

      # The customer's meetings (AQ-06 §11.2): their own, and *Add to calendar*.
      get "/meetings", MeetingController, :index
      get "/meetings/:id/ics", MeetingController, :ics

      # The customer's approvals (AQ-07 §11.2): what waits on them, deciding,
      # comments. `count` before `:id`, so it is not an id.
      get "/approvals", ApprovalController, :index
      get "/approvals/count", ApprovalController, :count
      get "/approvals/:id", ApprovalController, :show
      post "/approvals/:id/decide", ApprovalController, :decide
      get "/approvals/:id/comments", ApprovalController, :comments
      post "/approvals/:id/comments", ApprovalController, :comment
      delete "/approval-comments/:id", ApprovalController, :delete_comment
      get "/leads/:id/approvals", ApprovalController, :for_lead
    end
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
