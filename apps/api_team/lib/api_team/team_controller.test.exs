defmodule ApiTeam.TeamControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)
    %{org: org, backend: backend, frontend: frontend, admin: admin, lead: lead, member: member}
  end

  test "GET /teams, POST /teams, GET/PATCH /teams/:id, archive", %{
    admin: admin,
    member: member,
    backend: backend,
    frontend: frontend
  } do
    conn = call(admin, :get, "/v1/teams")
    assert conn.status == 200
    assert length(body(conn)) == 2
    assert [%{"id" => id}] = body(call(member, :get, "/v1/teams"))
    assert id == backend.id

    conn = call(admin, :post, "/v1/teams", %{name: "Data squad"})
    assert conn.status == 201

    assert %{
             "id" => _id,
             "name" => "Data squad",
             "slug" => "data-squad",
             "member_count" => 0,
             "archived_at" => nil
           } = body(conn)

    assert body(call(member, :get, "/v1/teams/#{backend.id}"))["member_count"] == 2

    assert call(admin, :post, "/v1/teams", %{name: ""}).status == 422
    assert code(call(member, :post, "/v1/teams", %{name: "Nope"})) == "forbidden"

    assert body(call(member, :get, "/v1/teams/#{backend.id}"))["name"] == "Backend squad"
    assert call(member, :get, "/v1/teams/#{frontend.id}").status == 404

    assert body(call(admin, :patch, "/v1/teams/#{backend.id}", %{name: "Backend"}))["name"] ==
             "Backend"

    assert body(call(admin, :post, "/v1/teams/#{backend.id}/archive"))["archived_at"]
  end

  test "team settings for a lead; a member is refused with words", %{
    lead: lead,
    member: member,
    backend: backend
  } do
    conn = call(lead, :get, "/v1/teams/#{backend.id}/settings")
    assert conn.status == 200
    assert body(conn)["customer_sees_staff_names"] == true
    assert map_size(body(conn)) == 6

    conn =
      call(lead, :put, "/v1/teams/#{backend.id}/settings", %{customer_sees_staff_names: false})

    assert body(conn)["customer_sees_staff_names"] == false
    assert call(member, :get, "/v1/teams/#{backend.id}/settings").status == 403
  end

  test "members: list, change role (with the guards), remove", %{
    admin: admin,
    lead: lead,
    member: member,
    backend: backend
  } do
    conn = call(member, :get, "/v1/teams/#{backend.id}/members")
    assert conn.status == 200
    assert Enum.map(body(conn), & &1["role"]) |> Enum.sort() == ["lead", "member"]
    assert Enum.all?(body(conn), &Map.has_key?(&1, "display_name"))

    above =
      call(lead, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{role: "manager"})

    assert above.status == 403
    assert body(above)["error"]["code"] == "role_above_yours"
    assert body(above)["error"]["message"] == "Only a manager can make a manager."

    conn = call(lead, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{role: "lead"})
    assert conn.status == 200
    assert body(conn)["role"] == "lead"

    assert call(lead, :post, "/v1/teams/#{backend.id}/members/#{member.id}/role", %{}).status ==
             422

    # The team keeps a lead: both are leads now, so one may go.
    assert call(admin, :delete, "/v1/teams/#{backend.id}/members/#{member.id}").status == 204
    last = call(admin, :delete, "/v1/teams/#{backend.id}/members/#{lead.id}")
    assert last.status == 204

    # With one member left who is not a lead, removing the only lead is refused.
    org = admin |> scope_for() |> Map.fetch!(:organisation)
    team = team_fixture(org)
    only_lead = member_fixture(team, :lead)
    _member = member_fixture(team, :member)
    refused = call(admin, :delete, "/v1/teams/#{team.id}/members/#{only_lead.id}")
    assert refused.status == 403
    assert body(refused)["error"]["message"] =~ "needs a lead or a manager"
  end
end
