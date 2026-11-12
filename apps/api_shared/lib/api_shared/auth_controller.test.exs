defmodule ApiShared.AuthControllerTest do
  @moduledoc """
  Every `/auth` route of AQ-01 §6.1: its status and its shape, through the
  shared router with a real pipeline. `async: false` for the Google stand-in.
  """

  use ApiShared.SharedCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Core.Auth.Guardian

  setup do
    org = organisation_fixture(name: "Regbits BD")
    admin = admin_fixture(org, email: "dawud@example.com")
    %{org: org, admin: admin}
  end

  describe "POST /auth/login" do
    test "answers the pair and the user", %{admin: admin} do
      conn =
        request(
          build(:post, "/v1/auth/login", %{email: "Dawud@example.com", password: valid_password()})
        )

      assert conn.status == 200
      assert %{"access_token" => _a, "refresh_token" => _r, "user" => user} = body(conn)
      assert user["id"] == admin.id
      assert user["person"]["display_name"] == "Test Person"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "the same words for a wrong email and a wrong password" do
      wrong =
        request(
          build(:post, "/v1/auth/login", %{email: "dawud@example.com", password: "nope nope nope"})
        )

      unknown =
        request(
          build(:post, "/v1/auth/login", %{
            email: "nobody@example.com",
            password: valid_password()
          })
        )

      missing = request(build(:post, "/v1/auth/login", %{}))

      for conn <- [wrong, unknown, missing] do
        assert conn.status == 401
        assert body(conn)["error"]["code"] == "invalid_credentials"
      end

      assert body(wrong)["error"]["message"] == body(unknown)["error"]["message"]
    end

    test "a suspended account is told so", %{admin: admin} do
      {:ok, _user} = Data.Accounts.set_suspended(admin, DateTime.utc_now())

      conn =
        request(build(:post, "/v1/auth/login", %{email: admin.email, password: valid_password()}))

      assert conn.status == 403
      assert body(conn)["error"]["code"] == "account_suspended"
    end
  end

  describe "POST /auth/google" do
    setup do
      original = Application.get_env(:core, :google)
      Application.put_env(:core, :google, Keyword.merge(original, client_id: nil, stand_in: true))
      on_exit(fn -> Application.put_env(:core, :google, original) end)
      :ok
    end

    test "the stand-in signs in an existing account; a stranger is not found", %{admin: admin} do
      conn = request(build(:post, "/v1/auth/google", %{id_token: "dev:#{admin.email}"}))
      assert conn.status == 200
      assert body(conn)["user"]["id"] == admin.id

      conn = request(build(:post, "/v1/auth/google", %{id_token: "dev:stranger@example.com"}))
      assert conn.status == 404
      assert body(conn)["error"]["code"] == "account_not_found"

      conn = request(build(:post, "/v1/auth/google", %{id_token: "garbage"}))
      assert conn.status == 401
    end
  end

  describe "POST /auth/refresh" do
    test "a new pair; the old refresh token dies", %{admin: admin} do
      {:ok, tokens} = Guardian.tokens_for(admin)
      conn = request(build(:post, "/v1/auth/refresh", %{refresh_token: tokens.refresh_token}))
      assert conn.status == 200
      assert %{"access_token" => _a, "refresh_token" => _r} = body(conn)
      assert map_size(body(conn)) == 2

      again = request(build(:post, "/v1/auth/refresh", %{refresh_token: tokens.refresh_token}))
      assert again.status == 401
      assert body(again)["error"]["code"] == "invalid_refresh_token"
      assert request(build(:post, "/v1/auth/refresh", %{})).status == 401
    end
  end

  describe "POST /auth/logout and /auth/logout-all" do
    test "logout ends this session only; logout-all every one", %{admin: admin} do
      {:ok, one} = Guardian.tokens_for(admin)
      {:ok, two} = Guardian.tokens_for(admin)

      conn =
        request(
          build(:post, "/v1/auth/logout")
          |> put_req_header("authorization", "Bearer " <> one.access_token)
        )

      assert conn.status == 204
      assert {:error, _gone} = Guardian.decode_and_verify(one.refresh_token)
      assert {:ok, _still} = Guardian.decode_and_verify(two.access_token)

      conn =
        request(
          build(:post, "/v1/auth/logout-all")
          |> put_req_header("authorization", "Bearer " <> two.access_token)
        )

      assert conn.status == 204

      assert request(
               build(:get, "/v1/me")
               |> put_req_header("authorization", "Bearer " <> two.access_token)
             ).status == 401
    end

    test "without a token, 401" do
      assert request(build(:post, "/v1/auth/logout")).status == 401

      assert body(request(build(:post, "/v1/auth/logout-all")))["error"]["code"] ==
               "unauthenticated"
    end
  end

  describe "GET /auth/invitations/:code and POST .../accept" do
    test "the preview, then accepting with a name and a password signs the person in", %{org: org} do
      team = team_fixture(org, name: "Backend squad")
      inv = invitation_fixture(org, team: team, role: :lead, email: "hira@example.com")

      conn = request(build(:get, "/v1/auth/invitations/#{inv.code}"))
      assert conn.status == 200

      assert %{
               "kind" => "team_member",
               "organisation_name" => "Regbits BD",
               "team_name" => "Backend squad",
               "role" => "lead",
               "customer_name" => nil,
               "invited_name" => "Invited Person",
               "email" => "hira@example.com",
               "expires_at" => _at,
               "has_account" => false
             } = body(conn)

      conn =
        request(
          build(:post, "/v1/auth/invitations/#{inv.code}/accept", %{
            name: "Hira Khan",
            password: "a fine long password"
          })
        )

      assert conn.status == 201

      assert %{"access_token" => _a, "refresh_token" => _r, "landing" => "/", "user" => user} =
               body(conn)

      assert user["email"] == "hira@example.com"

      used = request(build(:get, "/v1/auth/invitations/#{inv.code}"))
      assert used.status == 410
      assert body(used)["error"]["code"] == "invitation_used"
    end

    test "a signed-in account with the same email accepts with one press", %{
      org: org,
      admin: admin
    } do
      inv = invitation_fixture(org, team: team_fixture(org), role: :member, email: admin.email)
      conn = request(build(:post, "/v1/auth/invitations/#{inv.code}/accept") |> authed(admin))
      assert conn.status == 201
      assert body(conn)["user"]["id"] == admin.id
    end

    test "unknown, expired and weak answer their codes", %{org: org} do
      assert request(build(:get, "/v1/auth/invitations/ZZ-ZZZZ")).status == 404

      assert body(request(build(:get, "/v1/auth/invitations/nonsense")))["error"]["code"] ==
               "invitation_invalid"

      expired = invitation_fixture(org, expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      conn = request(build(:get, "/v1/auth/invitations/#{expired.code}"))
      assert conn.status == 410
      assert body(conn)["error"]["code"] == "invitation_expired"

      inv = invitation_fixture(org)

      conn =
        request(
          build(:post, "/v1/auth/invitations/#{inv.code}/accept", %{name: "x", password: "short"})
        )

      assert conn.status == 422
      assert body(conn)["error"]["code"] == "password_too_weak"
    end

    test "an existing email must sign in first", %{org: org, admin: admin} do
      inv = invitation_fixture(org, team: team_fixture(org), email: admin.email)

      conn =
        request(
          build(:post, "/v1/auth/invitations/#{inv.code}/accept", %{
            name: "x",
            password: "a fine long password"
          })
        )

      assert conn.status == 409
      assert body(conn)["error"]["code"] == "email_taken"
    end
  end

  describe "POST /auth/password/forgot and /reset" do
    test "forgot is 202 whatever happened; reset sets the password and revokes tokens", %{
      admin: admin
    } do
      {:ok, tokens} = Guardian.tokens_for(admin)

      assert request(build(:post, "/v1/auth/password/forgot", %{email: "nobody@example.com"})).status ==
               202

      assert request(build(:post, "/v1/auth/password/forgot", %{email: admin.email})).status ==
               202

      [job] = all_enqueued(worker: Notifire.Workers.PasswordResetWorker)

      conn =
        request(
          build(:post, "/v1/auth/password/reset", %{
            token: job.args["secret"],
            password: "a completely new one"
          })
        )

      assert conn.status == 204
      assert {:error, _gone} = Guardian.decode_and_verify(tokens.access_token)

      assert request(
               build(:post, "/v1/auth/login", %{
                 email: admin.email,
                 password: "a completely new one"
               })
             ).status == 200

      dead =
        request(
          build(:post, "/v1/auth/password/reset", %{
            token: job.args["secret"],
            password: "a completely new one"
          })
        )

      assert dead.status == 410
      assert body(dead)["error"]["code"] == "token_invalid"
    end

    test "a weak password on reset is 422", %{admin: admin} do
      request(build(:post, "/v1/auth/password/forgot", %{email: admin.email}))
      [job] = all_enqueued(worker: Notifire.Workers.PasswordResetWorker)

      conn =
        request(
          build(:post, "/v1/auth/password/reset", %{token: job.args["secret"], password: "short"})
        )

      assert conn.status == 422
    end
  end
end
