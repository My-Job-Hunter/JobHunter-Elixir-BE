defmodule ApiTeam.CustomerControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)
    imran = customer_fixture(org, [frontend], display_name: "Imran")

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: admin,
      lead: lead,
      member: member,
      imran: imran
    }
  end

  test "POST /customers (201, shape), GET list with filters, GET/PATCH /customers/:id, 404 across teams",
       %{
         lead: lead,
         member: member,
         backend: backend,
         imran: imran
       } do
    conn =
      call(lead, :post, "/v1/customers", %{
        display_name: "Tanweer",
        email: "tanweer@example.com",
        phone_e164: "+923001234567",
        team_ids: [backend.id]
      })

    assert conn.status == 201

    assert %{
             "id" => id,
             "display_name" => "Tanweer",
             "email" => "tanweer@example.com",
             "status" => "invited",
             "timezone" => "Asia/Karachi",
             "started_on" => nil,
             "last_signed_in_at" => nil,
             "teams" => [%{"name" => "Backend squad"}],
             "profiles" => [],
             "owners" => []
           } = body(conn)

    assert call(member, :post, "/v1/customers", %{display_name: "x", email: "x@example.com"}).status ==
             403

    assert call(lead, :post, "/v1/customers", %{display_name: "", email: "nope"}).status == 422

    assert call(lead, :post, "/v1/customers", %{
             display_name: "tanweer",
             email: "TANWEER@example.com"
           }).status ==
             422

    conn = call(member, :get, "/v1/customers")
    assert conn.status == 200
    assert Enum.map(body(conn), & &1["id"]) == [id]
    refute Enum.any?(body(conn), &(&1["id"] == imran.id))

    assert [%{"id" => ^id}] =
             body(call(lead, :get, "/v1/customers?q=tanw&status=invited"))

    assert [] = body(call(lead, :get, "/v1/customers?status=active"))
    assert call(lead, :get, "/v1/customers?status=pirate").status == 422

    assert body(call(member, :get, "/v1/customers/#{id}"))["display_name"] == "Tanweer"
    assert call(member, :get, "/v1/customers/#{imran.id}").status == 404
    assert call(lead, :get, "/v1/customers/#{imran.id}").status == 404

    conn =
      call(lead, :patch, "/v1/customers/#{id}", %{location_text: "Lahore", country_code: "PK"})

    assert body(conn)["location_text"] == "Lahore"
    assert call(member, :patch, "/v1/customers/#{id}", %{location_text: "x"}).status == 403
  end

  test "status, teams and invite are verbs; a member is refused with words", %{
    admin: admin,
    lead: lead,
    member: member,
    backend: backend,
    frontend: frontend
  } do
    customer = customer_fixture(admin |> scope_for() |> Map.fetch!(:organisation), [backend])

    conn = call(lead, :post, "/v1/customers/#{customer.id}/status", %{status: "active"})
    assert conn.status == 200
    assert body(conn)["status"] == "active"
    assert body(conn)["started_on"]

    assert call(lead, :post, "/v1/customers/#{customer.id}/status", %{status: "gone"}).status ==
             422

    refused = call(member, :post, "/v1/customers/#{customer.id}/status", %{status: "paused"})
    assert refused.status == 403
    assert body(refused)["error"]["message"] =~ "lead or above"

    # A lead of Backend cannot assign Frontend (not theirs); an admin can.
    assert call(lead, :post, "/v1/customers/#{customer.id}/teams", %{team_id: frontend.id}).status ==
             404

    conn = call(admin, :post, "/v1/customers/#{customer.id}/teams", %{team_id: frontend.id})
    assert conn.status == 201
    assert length(body(conn)["teams"]) == 2
    conn = call(admin, :delete, "/v1/customers/#{customer.id}/teams/#{frontend.id}")
    assert conn.status == 200
    assert [%{"id" => team_id}] = body(conn)["teams"]
    assert team_id == backend.id

    conn = call(lead, :post, "/v1/customers/#{customer.id}/invite")
    assert conn.status == 201

    assert %{"kind" => "customer", "customer_name" => name, "link" => link, "state" => "open"} =
             body(conn)

    assert name == customer.display_name
    assert String.starts_with?(link, "http://localhost:5801/invite/")
    assert call(lead, :post, "/v1/customers/#{customer.id}/invite").status == 200
    assert call(member, :post, "/v1/customers/#{customer.id}/invite").status == 403
  end

  test "notes: a member reads, a lead writes, the author edits, delete is 204", %{
    lead: lead,
    member: member,
    backend: backend,
    admin: admin
  } do
    customer = customer_fixture(admin |> scope_for() |> Map.fetch!(:organisation), [backend])

    conn =
      call(lead, :post, "/v1/customers/#{customer.id}/notes", %{body_md: "Prefers mornings."})

    assert conn.status == 201

    assert %{"id" => id, "body_md" => "Prefers mornings.", "author_name" => "Test Person"} =
             body(conn)

    assert call(lead, :post, "/v1/customers/#{customer.id}/notes", %{body_md: "  "}).status == 422

    assert call(member, :post, "/v1/customers/#{customer.id}/notes", %{body_md: "x"}).status ==
             403

    assert [%{"id" => ^id}] =
             body(call(member, :get, "/v1/customers/#{customer.id}/notes"))

    assert call(member, :patch, "/v1/notes/#{id}", %{body_md: "y"}).status == 403
    conn = call(lead, :patch, "/v1/notes/#{id}", %{body_md: "Prefers afternoons."})
    assert body(conn)["body_md"] == "Prefers afternoons."
    assert body(conn)["edited_at"]
    assert call(lead, :delete, "/v1/notes/#{id}").status == 204
    assert body(call(member, :get, "/v1/customers/#{customer.id}/notes")) == []
    assert call(lead, :delete, "/v1/notes/#{id}").status == 404
  end
end
