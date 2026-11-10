defmodule ApiTeam.SkillControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    %{org: org, lead: member_fixture(team, :lead), member: member_fixture(team, :member)}
  end

  test "GET /skills?q, POST /skills (slug from the name, unique), archive by a lead", %{
    org: org,
    lead: lead,
    member: member
  } do
    skill_fixture(org, name: "Elixir", category: "languages")

    conn = call(member, :post, "/v1/skills", %{name: "Node.js", category: "frameworks"})
    assert conn.status == 201

    assert %{"id" => id, "name" => "Node.js", "slug" => "node-js", "category" => "frameworks"} =
             body(conn)

    assert call(member, :post, "/v1/skills", %{name: "node js", category: "frameworks"}).status ==
             422

    assert call(member, :post, "/v1/skills", %{name: "", category: "x"}).status == 422

    conn = call(member, :get, "/v1/skills")
    assert Enum.map(body(conn), & &1["name"]) == ["Node.js", "Elixir"]
    assert [%{"name" => "Elixir"}] = body(call(member, :get, "/v1/skills?q=eli"))

    assert call(member, :post, "/v1/skills/#{id}/archive").status == 403
    assert body(call(lead, :post, "/v1/skills/#{id}/archive"))["archived_at"]
    assert [%{"name" => "Elixir"}] = body(call(member, :get, "/v1/skills"))
    assert call(lead, :post, "/v1/skills/#{Ecto.UUID.generate()}/archive").status == 404
    assert call(user_fixture(), :get, "/v1/skills").status == 404
  end
end
