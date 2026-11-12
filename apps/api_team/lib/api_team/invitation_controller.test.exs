defmodule ApiTeam.InvitationControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)

    %{
      org: org,
      backend: backend,
      admin: admin,
      lead: lead,
      member: member_fixture(backend, :member)
    }
  end

  test "POST /invitations issues (201) and then answers the open one (200); GET lists; revoke and resend",
       %{admin: admin, lead: lead, member: member, backend: backend} do
    params = %{
      kind: "team_member",
      email: "hira@example.com",
      invited_name: "Hira Khan",
      team_id: backend.id,
      role: "member"
    }

    conn = call(lead, :post, "/v1/invitations", params)
    assert conn.status == 201

    assert %{
             "id" => id,
             "code" => code,
             "state" => "open",
             "team_name" => "Backend squad",
             "accept_url" => url
           } = body(conn)

    assert url == "http://localhost:5800/invite/#{code}"

    again = call(lead, :post, "/v1/invitations", params)
    assert again.status == 200
    assert body(again)["id"] == id

    assert call(member, :post, "/v1/invitations", params).status == 403

    # §8.5: a team lead is the system admin's to invite; `kind: admin` is a field error.
    refused =
      call(lead, :post, "/v1/invitations", %{params | role: "lead", email: "x@example.com"})

    assert refused.status == 403
    assert body(refused)["error"]["message"] == "Only the system admin can do that."

    assert call(admin, :post, "/v1/invitations", %{params | role: "lead", email: "y@example.com"}).status ==
             201

    admin_kind = call(admin, :post, "/v1/invitations", %{params | kind: "admin"})
    assert admin_kind.status == 422 and Map.has_key?(body(admin_kind)["error"]["details"], "kind")

    assert call(admin, :post, "/v1/invitations", %{params | email: "nope"}).status == 422

    conn = call(admin, :get, "/v1/invitations?state=open")
    assert conn.status == 200
    assert Enum.any?(body(conn), &(&1["id"] == id)) and length(body(conn)) == 2
    assert call(member, :get, "/v1/invitations").status == 403

    assert body(call(admin, :post, "/v1/invitations/#{id}/resend"))["state"] == "open"
    conn = call(admin, :post, "/v1/invitations/#{id}/revoke")
    assert body(conn)["state"] == "revoked"
    assert call(admin, :post, "/v1/invitations/#{id}/revoke").status == 404
    assert call(admin, :post, "/v1/invitations/#{Ecto.UUID.generate()}/revoke").status == 404
  end
end
