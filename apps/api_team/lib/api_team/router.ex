defmodule ApiTeam.Router do
  @moduledoc """
  The API for the team console (5800): the manager, team leads, members and
  the admin. `Api.Endpoint` forwards `/team` here, so `/v1/…` below is
  `/team/v1/…` to a client.

  It includes the shared routes (`ApiShared.Routes`: `/info`, `/auth/*`,
  `/me/*`, `/media/*`) and adds the console's own (JH-01 §6.2): the
  organisation, its admins and audit log, teams with their members and
  settings, invitations and people; customers with their profiles,
  channels, documents and notes, and the skills vocabulary (P1.2). Every
  later phase adds its staff routes here (PLAN §15.4).
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    plug :accepts, ["json"]
    plug ApiShared.Plugs.App, "team"
  end

  ApiShared.Routes.shared_pipelines()

  # `:jh_shared` puts `cache-control: no-store` on every answer: a version
  # from a proxy is the wrong version, and these carry tokens.
  scope "/v1" do
    pipe_through [:api, :jh_shared]

    ApiShared.Routes.shared_routes()

    scope "/", ApiTeam do
      pipe_through :jh_authenticated

      get "/org", OrgController, :show
      put "/org/settings", OrgController, :update_settings
      get "/org/admins", OrgController, :admins
      post "/org/admins", OrgController, :grant_admin
      delete "/org/admins/:user_id", OrgController, :revoke_admin
      get "/org/audit", OrgController, :audit

      get "/teams", TeamController, :index
      post "/teams", TeamController, :create
      get "/teams/:id", TeamController, :show
      patch "/teams/:id", TeamController, :update
      post "/teams/:id/archive", TeamController, :archive
      get "/teams/:id/settings", TeamController, :settings
      put "/teams/:id/settings", TeamController, :put_settings
      get "/teams/:id/members", TeamController, :members
      post "/teams/:id/members/:user_id/role", TeamController, :change_role
      delete "/teams/:id/members/:user_id", TeamController, :remove_member

      get "/invitations", InvitationController, :index
      post "/invitations", InvitationController, :create
      post "/invitations/:id/revoke", InvitationController, :revoke
      post "/invitations/:id/resend", InvitationController, :resend

      get "/people", PeopleController, :index
      post "/people/:user_id/suspend", PeopleController, :suspend
      post "/people/:user_id/unsuspend", PeopleController, :unsuspend

      # Customers (P1.2): the record, its teams, the portal invitation, the notes.
      get "/customers", CustomerController, :index
      post "/customers", CustomerController, :create
      get "/customers/:id", CustomerController, :show
      patch "/customers/:id", CustomerController, :update
      post "/customers/:id/status", CustomerController, :change_status
      post "/customers/:id/teams", CustomerController, :assign_team
      delete "/customers/:id/teams/:team_id", CustomerController, :remove_team
      post "/customers/:id/invite", CustomerController, :invite
      get "/customers/:id/notes", CustomerController, :notes
      post "/customers/:id/notes", CustomerController, :create_note
      patch "/notes/:id", CustomerController, :update_note
      delete "/notes/:id", CustomerController, :delete_note

      get "/customers/:id/profiles", ProfileController, :index
      post "/customers/:id/profiles", ProfileController, :create
      get "/profiles/:id", ProfileController, :show
      patch "/profiles/:id", ProfileController, :update
      post "/profiles/:id/archive", ProfileController, :archive
      put "/profiles/:id/owners", ProfileController, :put_owners
      put "/profiles/:id/skills", ProfileController, :put_skills
      put "/profiles/:id/channels", ProfileController, :put_channels

      get "/customers/:id/channels", ChannelController, :index
      post "/customers/:id/channels", ChannelController, :create
      get "/channels/:id", ChannelController, :show
      patch "/channels/:id", ChannelController, :update
      post "/channels/:id/archive", ChannelController, :archive

      get "/profiles/:id/documents", DocumentController, :index
      post "/profiles/:id/documents", DocumentController, :create
      put "/profiles/:id/default-document", DocumentController, :put_default
      get "/documents/:id", DocumentController, :show
      patch "/documents/:id", DocumentController, :update
      post "/documents/:id/archive", DocumentController, :archive
      post "/documents/:id/new-version", DocumentController, :new_version

      get "/skills", SkillController, :index
      post "/skills", SkillController, :create
      post "/skills/:id/archive", SkillController, :archive
    end
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
