defmodule ApiTeam.OrgControllerTest do
  use ApiTeam.TeamCase, async: true

  @admin_words "Only the system admin can do that."

  setup do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org)
    admin = admin_fixture(org)
    lead = member_fixture(team, :lead)
    %{org: org, team: team, admin: admin, lead: lead, member: member_fixture(team, :member)}
  end

  test "GET /org and PUT /org/settings: Settings › System, the system admin's alone", %{
    org: org,
    admin: admin,
    lead: lead,
    member: member
  } do
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

    for who <- [lead, member] do
      refused = call(who, :get, "/v1/org")
      assert refused.status == 403
      assert body(refused)["error"]["message"] == @admin_words
      assert code(call(who, :put, "/v1/org/settings", %{warning_days: 2})) == "forbidden"
    end
  end

  test "the admins routes are gone (QP4a-21)", %{admin: admin, lead: lead} do
    assert call(admin, :get, "/v1/org/admins").status == 404
    assert call(admin, :post, "/v1/org/admins", %{user_id: lead.id}).status == 404
    assert call(admin, :delete, "/v1/org/admins/#{lead.id}").status == 404
  end

  test "GET /org/audit pages the log for the system admin, not a team lead or a member", %{
    admin: admin,
    lead: lead,
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
    assert call(lead, :get, "/v1/org/audit").status == 403
    assert call(member, :get, "/v1/org/audit").status == 403
    assert call(admin, :get, "/v1/org/audit?cursor=garbage").status == 422
  end
end
