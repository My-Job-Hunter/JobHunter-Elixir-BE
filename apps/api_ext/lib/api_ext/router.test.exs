defmodule ApiExt.RouterTest do
  @moduledoc """
  AQ-05 §11.1: what `/ext/v1` mounts. From the shared set only `/info`,
  `auth/refresh`, `auth/logout`, `GET /me` and the bell — nobody signs in
  inside the extension — and every route but `POST /session` needs a
  device token.
  """

  use ApiExt.ExtCase, async: true

  test "v1/info answers as ext" do
    conn = call(nil, :get, "/v1/info")

    assert conn.status == 200
    assert body(conn) == %{"app" => "ext", "api" => "v1", "version" => "0.1.0"}
  end

  test "an unknown path answers 404 not_found" do
    conn = call(nil, :get, "/v1/nope")

    assert conn.status == 404
    assert code(conn) == "not_found"
  end

  test "no sign-in, password, invitation, profile-edit or upload route" do
    for {method, path} <- [
          post: "/v1/auth/login",
          post: "/v1/auth/google",
          post: "/v1/auth/password/forgot",
          post: "/v1/auth/password/reset",
          get: "/v1/auth/invitations/abc",
          post: "/v1/auth/invitations/abc/accept",
          post: "/v1/auth/logout-all",
          patch: "/v1/me",
          get: "/v1/me/sessions",
          post: "/v1/media",
          get: "/v1/notifications/groups",
          post: "/v1/notifications/read-all"
        ] do
      conn = call(nil, method, path)
      assert conn.status == 404, "#{method} #{path} answered #{conn.status}"
    end
  end

  test "every other route needs a token: 401 unauthenticated" do
    for {method, path} <- [
          get: "/v1/me",
          get: "/v1/notifications",
          get: "/v1/notifications/count",
          post: "/v1/auth/logout",
          delete: "/v1/session",
          get: "/v1/context",
          get: "/v1/config",
          get: "/v1/jobs/lookup",
          post: "/v1/jobs/capture",
          post: "/v1/leads/save",
          post: "/v1/leads/applied",
          post: "/v1/leads/x/apply-again",
          post: "/v1/health"
        ] do
      conn = call(nil, method, path)
      assert conn.status == 401, "#{method} #{path} answered #{conn.status}"
      assert code(conn) == "unauthenticated"
    end
  end
end
