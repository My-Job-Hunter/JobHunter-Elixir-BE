defmodule ApiTeam.OrgControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org)
    admin = admin_fixture(org)
    manager = member_fixture(team, :manager)
    %{org: org, team: team, admin: admin, manager: manager, member: member_fixture(team, :member)}
  end

  test "GET /org and PUT /org/settings", %{org: org, admin: admin, member: member} do
    conn = call(admin, :get, "/v1/org")
    assert conn.status == 200

    assert %{
             "id" => id,
             "name" => "Regbits BD",
             "settings" => %{"follow_up_gap_days" => 3}
           } = body(conn)

    assert id == org.id

    conn = call(admin, :put, "/v1/org/settings", %{follow_up_gap_days: 4, currency_code: "PKR"})
    assert conn.status == 200
    assert body(conn)["settings"]["follow_up_gap_days"] == 4
    assert body(conn)["currency_code"] == "PKR"

    assert call(admin, :put, "/v1/org/settings", %{warning_days: 0}).status == 422
    assert call(member, :get, "/v1/org").status == 403
    assert code(call(member, :put, "/v1/org/settings", %{warning_days: 2})) == "forbidden"
  end

  test "admins: list, grant, revoke, the last-admin guard", %{admin: admin, manager: manager} do
    conn = call(admin, :get, "/v1/org/admins")
    assert conn.status == 200
    assert [%{"user_id" => id}] = body(conn)
    assert id == admin.id

    conn = call(admin, :post, "/v1/org/admins", %{user_id: manager.id})
    assert conn.status == 201
    assert body(conn)["user_id"] == manager.id
    assert call(admin, :post, "/v1/org/admins", %{user_id: manager.id}).status == 409
    assert call(admin, :post, "/v1/org/admins", %{}).status == 422

    assert call(admin, :delete, "/v1/org/admins/#{manager.id}").status == 204
    conn = call(admin, :delete, "/v1/org/admins/#{admin.id}")
    assert conn.status == 409

    assert body(conn)["error"] == %{
             "code" => "last_admin",
             "message" => "The organisation needs one admin. Grant another first.",
             "details" => %{}
           }

    assert call(manager, :get, "/v1/org/admins").status == 403
  end

  test "GET /org/audit pages the log for an admin and a manager, not a member", %{
    admin: admin,
    manager: manager,
    member: member,
    team: team
  } do
    call(admin, :patch, "/v1/teams/#{team.id}", %{name: "Renamed"})
    conn = call(admin, :get, "/v1/org/audit")
    assert conn.status == 200
    assert %{"items" => [event | _rest], "next_cursor" => nil} = body(conn)

    assert %{
             "action" => "updated",
             "subject_kind" => "teams",
             "actor_name" => "Test Person",
             "via" => "web",
             "before" => %{"name" => _old}
           } = event

    conn = call(admin, :get, "/v1/org/audit?subject_kind=teams&subject_id=#{team.id}")
    assert length(body(conn)["items"]) == 1
    assert call(manager, :get, "/v1/org/audit").status == 200
    assert call(member, :get, "/v1/org/audit").status == 403
    assert call(admin, :get, "/v1/org/audit?cursor=garbage").status == 422
  end
end
