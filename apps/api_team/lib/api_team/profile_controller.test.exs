defmodule ApiTeam.ProfileControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)
    tanweer = customer_fixture(org, [backend], display_name: "Tanweer")
    imran = customer_fixture(org, [frontend], display_name: "Imran")
    go = skill_fixture(org, name: "Go")

    %{
      org: org,
      backend: backend,
      lead: lead,
      member: member,
      tanweer: tanweer,
      imran: imran,
      go: go
    }
  end

  test "POST /customers/:id/profiles (201), GET list/show, PATCH facts vs pitch, archive", %{
    lead: lead,
    member: member,
    tanweer: tanweer,
    imran: imran
  } do
    conn =
      call(lead, :post, "/v1/customers/#{tanweer.id}/profiles", %{
        title: "Golang backend",
        headline: "Backend engineer, 6 years of Go",
        seniority: "mid_senior",
        years_experience: 6,
        engagement_types: ["full_time", "contract"],
        workplace_types: ["remote"],
        min_comp_minor: 400_000,
        min_comp_currency: "USD",
        min_comp_period: "month",
        daily_target: 40,
        owner_ids: [member.id]
      })

    assert conn.status == 201

    assert %{
             "id" => id,
             "title" => "Golang backend",
             "seniority" => "mid_senior",
             "min_comp_minor" => 400_000,
             "daily_target" => 40,
             "status" => "active",
             "default_pipeline_key" => "employment",
             "skills" => [],
             "channel_ids" => [],
             "default_document_id" => nil,
             "owners" => [%{"display_name" => "Test Person"}]
           } = body(conn)

    assert call(member, :post, "/v1/customers/#{tanweer.id}/profiles", %{title: "x"}).status ==
             403

    assert call(lead, :post, "/v1/customers/#{imran.id}/profiles", %{title: "x"}).status == 404

    assert call(lead, :post, "/v1/customers/#{tanweer.id}/profiles", %{title: "Golang backend"}).status ==
             422

    floor =
      call(lead, :post, "/v1/customers/#{tanweer.id}/profiles", %{
        title: "Half",
        min_comp_minor: 5
      })

    assert floor.status == 422
    assert Map.has_key?(body(floor)["error"]["details"], "min_comp_currency")

    assert [%{"id" => ^id}] =
             body(call(member, :get, "/v1/customers/#{tanweer.id}/profiles"))

    assert body(call(member, :get, "/v1/profiles/#{id}"))["title"] == "Golang backend"

    # A member changes facts, not the pitch; a mixed body is refused.
    conn = call(member, :patch, "/v1/profiles/#{id}", %{daily_target: 35, notice_days: 30})
    assert conn.status == 200
    assert body(conn)["daily_target"] == 35

    pitch = call(member, :patch, "/v1/profiles/#{id}", %{headline: "Different"})
    assert pitch.status == 403
    assert body(pitch)["error"]["message"] == "The pitch is the customer's or a lead's to change."

    mixed = call(lead, :patch, "/v1/profiles/#{id}", %{headline: "Different", daily_target: 10})
    assert mixed.status == 422
    assert body(mixed)["error"]["code"] == "validation_failed"
    assert Map.has_key?(body(mixed)["error"]["details"], "headline")

    assert body(call(lead, :patch, "/v1/profiles/#{id}", %{headline: "Different"}))["headline"] ==
             "Different"

    assert call(lead, :patch, "/v1/profiles/#{id}", %{}).status == 422

    assert call(member, :post, "/v1/profiles/#{id}/archive").status == 403
    assert body(call(lead, :post, "/v1/profiles/#{id}/archive"))["archived_at"]
    assert body(call(member, :get, "/v1/customers/#{tanweer.id}/profiles")) == []
  end

  test "PUT owners, skills, channels", %{
    lead: lead,
    member: member,
    tanweer: tanweer,
    imran: imran,
    go: go
  } do
    profile = profile_fixture(tanweer, title: "Golang backend")
    channel = channel_fixture(tanweer)
    theirs = channel_fixture(imran)

    conn =
      call(lead, :put, "/v1/profiles/#{profile.id}/owners", %{user_ids: [member.id, lead.id]})

    assert conn.status == 200
    assert length(body(conn)["owners"]) == 2

    assert call(member, :put, "/v1/profiles/#{profile.id}/owners", %{user_ids: [member.id]}).status ==
             403

    assert call(lead, :put, "/v1/profiles/#{profile.id}/owners", %{user_ids: [user_fixture().id]}).status ==
             404

    conn =
      call(member, :put, "/v1/profiles/#{profile.id}/skills", %{
        _json: [%{skill_id: go.id, level: "strong", years: 6}]
      })

    assert conn.status == 200

    assert [%{"skill_id" => skill_id, "name" => "Go", "level" => "strong", "years" => 6}] =
             body(conn)["skills"]

    assert skill_id == go.id

    assert call(member, :put, "/v1/profiles/#{profile.id}/skills", %{
             _json: [%{skill_id: Ecto.UUID.generate(), level: "strong"}]
           }).status == 422

    assert call(member, :put, "/v1/profiles/#{profile.id}/skills", %{
             _json: [%{skill_id: go.id, level: "wizard"}]
           }).status ==
             422

    conn = call(member, :put, "/v1/profiles/#{profile.id}/channels", %{channel_ids: [channel.id]})
    assert body(conn)["channel_ids"] == [channel.id]

    assert call(member, :put, "/v1/profiles/#{profile.id}/channels", %{channel_ids: [theirs.id]}).status ==
             404

    assert body(call(member, :put, "/v1/profiles/#{profile.id}/channels", %{channel_ids: []}))[
             "channel_ids"
           ] == []
  end
end
