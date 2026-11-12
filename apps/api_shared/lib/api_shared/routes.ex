defmodule ApiShared.Routes do
  @moduledoc """
  The routes more than one app serves, written once (copied from mCart).

  An app's router calls `shared_pipelines/0` at its top level, then
  `shared_routes/0` inside its own `/v1` scope, so one controller answers at
  each app's prefix: `/team/v1/auth/login`, `/client/v1/auth/login`. It ends
  with `not_found_routes/0`, so an unknown path under its prefix answers in
  the house error shape rather than with Phoenix's.

  AQ-01 §6.1: sign-in, the tokens, the invitation's two routes, forgot and
  reset, `/me` and its parts, the sessions and the three-step upload; AQ-02
  §7.1: the notifications; AQ-08 §11.4: the notifications' settings and
  push on a browser (`/me/push`). The
  rate limits of §6 are pipelines here: `auth/login` 10/min per IP,
  `password/forgot` 10/h per IP (and 3/h per address, in the context),
  `invitations/:code` 60/h per IP.
  """

  @doc """
  The pipelines the shared routes use. A router accepts a pipeline only at its
  top level, so this is the half that goes there.
  """
  defmacro shared_pipelines do
    quote do
      # Tokens and personal data, never cached.
      pipeline :aq_shared do
        plug ApiShared.Plugs.NoStore
      end

      # A verified bearer token, its user, and the scope built from them.
      pipeline :aq_authenticated do
        plug ApiShared.Plugs.AuthPipeline
        plug ApiShared.Plugs.Scope
      end

      # A token if there is one: accepting an invitation signed in or not.
      pipeline :aq_maybe_authenticated do
        plug ApiShared.Plugs.MaybeAuthPipeline
      end

      pipeline :aq_login_limit do
        plug Core.Plugs.RateLimit, name: "auth_login", limit: 10, scale_ms: 60_000
      end

      pipeline :aq_forgot_limit do
        plug Core.Plugs.RateLimit, name: "password_forgot", limit: 10, scale_ms: 3_600_000
      end

      pipeline :aq_invitation_limit do
        plug Core.Plugs.RateLimit, name: "invitation_code", limit: 60, scale_ms: 3_600_000
      end
    end
  end

  @doc "Expands to the shared routes, inside the caller's `/v1` scope and `:api, :aq_shared` pipeline."
  defmacro shared_routes do
    quote do
      get "/info", ApiShared.InfoController, :show

      scope "/auth", ApiShared do
        pipe_through :aq_login_limit
        post "/login", AuthController, :login
        post "/google", AuthController, :google
      end

      scope "/auth", ApiShared do
        post "/refresh", AuthController, :refresh
        post "/password/reset", AuthController, :reset_password
      end

      scope "/auth", ApiShared do
        pipe_through :aq_forgot_limit
        post "/password/forgot", AuthController, :forgot_password
      end

      scope "/auth", ApiShared do
        pipe_through :aq_invitation_limit
        get "/invitations/:code", AuthController, :invitation
      end

      scope "/auth", ApiShared do
        pipe_through [:aq_invitation_limit, :aq_maybe_authenticated]
        post "/invitations/:code/accept", AuthController, :accept_invitation
      end

      scope "/auth", ApiShared do
        pipe_through :aq_authenticated
        post "/logout", AuthController, :logout
        post "/logout-all", AuthController, :logout_all
      end

      scope "/me", ApiShared do
        pipe_through :aq_authenticated
        get "/", MeController, :show
        patch "/", MeController, :update
        put "/settings", MeController, :put_settings
        post "/password", MeController, :change_password
        post "/email", MeController, :request_email_change
        post "/email/confirm", MeController, :confirm_email_change
        get "/sessions", MeController, :sessions
        delete "/sessions/:sid", MeController, :revoke_session

        # Push on this browser (AQ-08 §11.4): `app` is the surface's.
        get "/push", PushController, :show
        post "/push", PushController, :create
        delete "/push", PushController, :delete
        post "/push/test", PushController, :test
      end

      scope "/media", ApiShared do
        pipe_through :aq_authenticated
        post "/", MediaController, :create
        put "/:id/blob", MediaController, :blob
        post "/:id/confirm", MediaController, :confirm
      end

      # The read is by signed link, not by token: an `<img src>` carries no header.
      get "/media/:id", ApiShared.MediaController, :show

      # The bell (AQ-02 §7.1): each person their own, in both apps. Its
      # settings (AQ-08 §11.4): the switches per group and channel.
      scope "/notifications", ApiShared do
        pipe_through :aq_authenticated
        get "/settings", NotificationSettingsController, :show
        put "/settings/groups/:key", NotificationSettingsController, :put_group
        get "/", NotificationController, :index
        get "/count", NotificationController, :count
        get "/groups", NotificationController, :groups
        post "/read-all", NotificationController, :read_all
        post "/:id/read", NotificationController, :read
      end
    end
  end

  @doc """
  The narrower set the extension mounts (AQ-05 §7, §11.1): `/info`,
  `auth/refresh`, `auth/logout`, `GET /me` and the bell's
  `GET /notifications`, `GET /notifications/count` and
  `POST /notifications/:id/read` — **no login, Google, password or
  invitation route**: nobody signs in inside the extension. The
  authenticated ones pipe through `:aq_authenticated` and then `pipelines`
  (the caller's: the device, its rate limit).
  """
  defmacro extension_routes(pipelines) do
    quote do
      get "/info", ApiShared.InfoController, :show

      scope "/auth", ApiShared do
        post "/refresh", AuthController, :refresh
      end

      scope "/", ApiShared do
        pipe_through [:aq_authenticated | unquote(pipelines)]
        post "/auth/logout", AuthController, :logout
        get "/me", MeController, :show
        get "/notifications", NotificationController, :index
        get "/notifications/count", NotificationController, :count
        post "/notifications/:id/read", NotificationController, :read
      end
    end
  end

  @doc """
  The last routes in a router: any method, any path not matched above, answers
  `404` with the code `not_found` through `ApiShared.FallbackController`.

  **A route rather than Phoenix's `NoRouteError`**, because a raised 404
  renders through the debugger page in dev (`debug_errors: true`), and the
  frontend would meet an HTML page in exactly the environment it is built in.
  This answers the same JSON in every environment.
  """
  defmacro not_found_routes do
    quote do
      match :*, "/*path", ApiShared.NotFoundController, :show
    end
  end
end
