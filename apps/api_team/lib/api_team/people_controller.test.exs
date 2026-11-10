defmodule ApiTeam.PeopleControllerTest do
  use ApiTeam.TeamCase, async: true

  alias Core.Auth.Guardian

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)
    %{org: org, backend: backend, admin: admin, lead: lead}
  end

  test "GET /people lists staff with teams, roles and the admin mark", %{
    admin: admin,
    lead: lead,
    backend: backend
  } do
    conn = call(admin, :get, "/v1/people")
    assert conn.status == 200
    people = body(conn)
    assert length(people) == 2
    lead_row = Enum.find(people, &(&1["user_id"] == lead.id))

    assert lead_row["teams"] == [
             %{"team_id" => backend.id, "name" => "Backend squad", "role" => "lead"}
           ]

    assert lead_row["is_admin"] == false
    assert Map.has_key?(lead_row, "last_signed_in_at")

    assert [%{"user_id" => id}] =
             body(call(admin, :get, "/v1/people?team_id=#{backend.id}"))

    assert id == lead.id
    assert call(user_fixture(), :get, "/v1/people").status == 404
  end

  test "POST /people/:id/suspend revokes the tokens; unsuspend lifts it", %{
    admin: admin,
    lead: lead
  } do
    {:ok, tokens} = Guardian.tokens_for(lead)
    assert call(admin, :post, "/v1/people/#{lead.id}/suspend").status == 204
    assert {:error, _gone} = Guardian.decode_and_verify(tokens.access_token)
    assert call(lead, :get, "/v1/me").status == 401
    assert call(admin, :post, "/v1/people/#{lead.id}/unsuspend").status == 204
    assert call(lead, :get, "/v1/me").status == 200

    assert call(lead, :post, "/v1/people/#{admin.id}/suspend").status == 403
    assert call(admin, :post, "/v1/people/#{admin.id}/suspend").status == 403
    assert call(admin, :post, "/v1/people/#{Ecto.UUID.generate()}/suspend").status == 404
  end
end
