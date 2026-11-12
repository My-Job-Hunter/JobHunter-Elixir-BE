defmodule ApiShared.MeControllerTest do
  use ApiShared.SharedCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Auth.Guardian

  setup do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org, name: "Backend squad")
    admin = admin_fixture(org)
    member_fixture(team, :lead, admin)
    %{org: org, team: team, admin: admin}
  end

  test "GET /me is the shape of §6.1", %{org: org, team: team, admin: admin} do
    conn = request(build(:get, "/v1/me") |> authed(admin))
    assert conn.status == 200

    assert %{
             "user" => %{
               "id" => user_id,
               "email" => email,
               "person" => %{
                 "display_name" => "Test Person",
                 "given_name" => nil,
                 "family_name" => nil,
                 "photo_url" => nil,
                 "timezone" => "Asia/Karachi",
                 "locale_code" => "en"
               }
             },
             "roles" => %{"admin" => true, "teams" => [team_json], "customer_id" => nil},
             "settings" => %{
               "theme" => "system",
               "quiet_hours_start" => nil,
               "quiet_hours_end" => nil,
               "digest_time" => "08:00:00",
               "digest_on" => true
             },
             "organisation" => %{
               "id" => org_id,
               "name" => "Regbits BD",
               "timezone" => "Asia/Karachi",
               "currency_code" => "USD"
             }
           } = body(conn)

    assert user_id == admin.id and email == admin.email and org_id == org.id
    assert team_json == %{"team_id" => team.id, "name" => "Backend squad", "role" => "lead"}
  end

  test "GET /me lists the switcher's teams by name; an admin's every team, admin where in none (AQ-03B §5.1)",
       %{org: org, team: team, admin: admin} do
    frontend = team_fixture(org, name: "Frontend squad")
    archived = team_fixture(org, name: "Archived squad")
    {:ok, _gone} = Data.Teams.archive(archived, DateTime.utc_now())

    assert body(request(build(:get, "/v1/me") |> authed(admin)))["teams"] == [
             %{"id" => team.id, "name" => "Backend squad", "role" => "lead"},
             %{"id" => frontend.id, "name" => "Frontend squad", "role" => "admin"}
           ]

    fiza = member_fixture(frontend, :member)
    member_fixture(archived, :lead, fiza)

    assert body(request(build(:get, "/v1/me") |> authed(fiza)))["teams"] == [
             %{"id" => frontend.id, "name" => "Frontend squad", "role" => "member"}
           ]
  end

  test "GET /me without a token is 401" do
    conn = request(build(:get, "/v1/me"))
    assert conn.status == 401
    assert body(conn)["error"]["code"] == "unauthenticated"
  end

  test "PATCH /me changes the person and answers the same shape", %{admin: admin} do
    conn =
      request(
        build(:patch, "/v1/me", %{display_name: "Dawud Kalim", timezone: "Europe/London"})
        |> authed(admin)
      )

    assert conn.status == 200
    assert body(conn)["user"]["person"]["display_name"] == "Dawud Kalim"
    assert body(conn)["user"]["person"]["timezone"] == "Europe/London"

    bad = request(build(:patch, "/v1/me", %{timezone: "Nowhere/Land"}) |> authed(admin))
    assert bad.status == 422
    assert body(bad)["error"]["details"]["timezone"]
  end

  test "PUT /me/settings answers the settings", %{admin: admin} do
    conn =
      request(build(:put, "/v1/me/settings", %{theme: "dark", digest_on: false}) |> authed(admin))

    assert conn.status == 200

    assert body(conn) == %{
             "theme" => "dark",
             "quiet_hours_start" => nil,
             "quiet_hours_end" => nil,
             "digest_time" => "08:00:00",
             "digest_on" => false
           }

    assert request(build(:put, "/v1/me/settings", %{theme: "neon"}) |> authed(admin)).status ==
             422
  end

  test "POST /me/password: 204, 422 on the field, 422 too weak", %{admin: admin} do
    assert request(
             build(:post, "/v1/me/password", %{
               current: valid_password(),
               new: "a brand new passphrase"
             })
             |> authed(admin)
           ).status == 204

    wrong =
      request(
        build(:post, "/v1/me/password", %{current: "not it", new: "a brand new passphrase"})
        |> authed(admin)
      )

    assert wrong.status == 422
    assert body(wrong)["error"]["details"]["current"] == ["is not right"]

    weak =
      request(
        build(:post, "/v1/me/password", %{current: "a brand new passphrase", new: "short"})
        |> authed(admin)
      )

    assert body(weak)["error"]["code"] == "password_too_weak"
  end

  test "POST /me/email then /me/email/confirm moves the login", %{admin: admin} do
    assert request(
             build(:post, "/v1/me/email", %{new_email: "moved@example.com"})
             |> authed(admin)
           ).status == 202

    [job] = all_enqueued(worker: Notifire.Workers.EmailChangeWorker)

    assert request(
             build(:post, "/v1/me/email/confirm", %{token: job.args["secret"]})
             |> authed(admin)
           ).status == 204

    assert body(request(build(:get, "/v1/me") |> authed(admin)))["user"]["email"] ==
             "moved@example.com"

    dead =
      request(build(:post, "/v1/me/email/confirm", %{token: job.args["secret"]}) |> authed(admin))

    assert dead.status == 410
    other = user_fixture()
    taken = request(build(:post, "/v1/me/email", %{new_email: other.email}) |> authed(admin))
    assert taken.status == 409
    assert body(taken)["error"]["code"] == "email_taken"
  end

  test "GET /me/sessions lists by sid with the current one marked; DELETE ends one", %{
    admin: admin
  } do
    {:ok, one} = Guardian.tokens_for(admin, %{"dev" => %{"agent" => "curl"}})
    {:ok, two} = Guardian.tokens_for(admin)
    {:ok, %{"sid" => sid_two}} = Guardian.decode_and_verify(two.access_token)

    conn =
      request(
        build(:get, "/v1/me/sessions")
        |> put_req_header("authorization", "Bearer " <> one.access_token)
      )

    assert conn.status == 200
    sessions = body(conn)
    assert length(sessions) == 2
    assert [current] = Enum.filter(sessions, & &1["current"])
    assert current["device"] == "curl"
    assert Enum.all?(sessions, &Map.has_key?(&1, "signed_in_at"))

    conn =
      request(
        build(:delete, "/v1/me/sessions/#{sid_two}")
        |> put_req_header("authorization", "Bearer " <> one.access_token)
      )

    assert conn.status == 204
    assert {:error, _gone} = Guardian.decode_and_verify(two.access_token)

    assert request(
             build(:delete, "/v1/me/sessions/#{sid_two}")
             |> put_req_header("authorization", "Bearer " <> one.access_token)
           ).status == 404
  end
end
