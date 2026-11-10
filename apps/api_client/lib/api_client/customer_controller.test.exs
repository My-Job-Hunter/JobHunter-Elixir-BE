defmodule ApiClient.CustomerControllerTest do
  @moduledoc """
  The portal (JH-01 §6.3), through `ApiClient.Plugs.CustomerScope`: a
  customer reaches their own rows, a staff account is told
  `not_a_customer`, another customer's rows answer 404.
  """

  use ApiClient.ClientCase, async: true

  alias Core.Organisation.Teams

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    fiza = member_fixture(backend, :member, user_fixture(display_name: "Fiza Noor"))

    qasim =
      member_fixture(
        backend,
        :member,
        user_fixture(display_name: "Qasim Ali", given_name: "Qasim")
      )

    hira = member_fixture(backend, :lead, user_fixture(display_name: "Hira Khan"))
    tanweer = customer_fixture(org, [backend, frontend], display_name: "Tanweer", login: true)
    naveed = customer_fixture(org, [backend], display_name: "Naveed", login: true)
    profile = profile_fixture(tanweer, title: "Golang backend", owners: [fiza, qasim])

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      hira: hira,
      tanweer: tanweer,
      naveed: naveed,
      profile: profile
    }
  end

  test "GET/PATCH /customer: own record; display_name and email are /me's", %{tanweer: tanweer} do
    conn = as_customer(tanweer, :get, "/v1/customer")
    assert conn.status == 200

    assert %{"display_name" => "Tanweer", "status" => "active", "teams" => [_one, _two]} =
             body(conn)

    conn =
      as_customer(tanweer, :patch, "/v1/customer", %{
        phone_e164: "+923001112233",
        display_name: "Nope"
      })

    assert body(conn)["phone_e164"] == "+923001112233"
    assert body(conn)["display_name"] == "Tanweer"
    assert as_customer(tanweer, :patch, "/v1/customer", %{timezone: "Mars/Olympus"}).status == 422
  end

  test "a staff account on the portal gets not_a_customer; no token is 401", %{hira: hira} do
    conn = call(hira, :get, "/v1/customer")
    assert conn.status == 404

    assert body(conn)["error"] == %{
             "code" => "not_a_customer",
             "message" => "This sign-in is for customers.",
             "details" => %{}
           }

    assert call(user_fixture(), :get, "/v1/profiles").status == 404

    bare = :get |> conn("/v1/profiles") |> ApiClient.Router.call(ApiClient.Router.init([]))
    assert bare.status == 401
  end

  test "GET /team: team names, and owners' first names only where the team allows", %{
    tanweer: tanweer,
    backend: backend,
    hira: hira
  } do
    conn = as_customer(tanweer, :get, "/v1/team")
    assert conn.status == 200

    assert [
             %{"name" => "Backend squad", "first_names" => ["Fiza", "Qasim"]},
             %{"name" => "Frontend squad", "first_names" => []}
           ] = Enum.sort_by(body(conn), & &1["name"])

    {:ok, _settings} =
      Teams.put_settings(scope_for(hira), backend.id, %{
        customer_sees_staff_names: false
      })

    assert [%{"name" => "Backend squad", "first_names" => []} | _rest] =
             Enum.sort_by(body(as_customer(tanweer, :get, "/v1/team")), & &1["name"])
  end

  test "profiles: own list, pitch and facts both allowed, another customer's is 404", %{
    tanweer: tanweer,
    naveed: naveed,
    profile: profile,
    org: org
  } do
    conn = as_customer(tanweer, :get, "/v1/profiles")
    assert conn.status == 200

    assert [%{"id" => id, "title" => "Golang backend", "owners" => [_fiza, _qasim]}] =
             body(conn)

    assert id == profile.id

    assert body(as_customer(tanweer, :patch, "/v1/profiles/#{id}", %{headline: "Go, since 2019"}))[
             "headline"
           ] ==
             "Go, since 2019"

    assert body(as_customer(tanweer, :patch, "/v1/profiles/#{id}", %{daily_target: 20}))[
             "daily_target"
           ] == 20

    assert as_customer(tanweer, :patch, "/v1/profiles/#{id}", %{headline: "x", daily_target: 1}).status ==
             422

    theirs = profile_fixture(naveed, title: "Elixir")
    assert as_customer(tanweer, :get, "/v1/profiles/#{theirs.id}").status == 404

    assert as_customer(tanweer, :patch, "/v1/profiles/#{theirs.id}", %{headline: "x"}).status ==
             404

    assert as_customer(tanweer, :get, "/v1/profiles/#{theirs.id}/documents").status == 404
    assert [%{"id" => theirs_id}] = body(as_customer(naveed, :get, "/v1/profiles"))
    assert theirs_id == theirs.id

    go = skill_fixture(org, name: "Go")
    assert [%{"name" => "Go"}] = body(as_customer(tanweer, :get, "/v1/skills"))

    conn =
      as_customer(tanweer, :put, "/v1/profiles/#{id}/skills", %{
        _json: [%{skill_id: go.id, level: "expert"}]
      })

    assert [%{"name" => "Go", "level" => "expert"}] = body(conn)["skills"]
  end

  test "channels and documents: own only, full run", %{
    tanweer: tanweer,
    naveed: naveed,
    profile: profile
  } do
    conn =
      as_customer(tanweer, :post, "/v1/channels", %{
        kind: "upwork",
        handle: "tanweer-dev",
        operated_by: "agency"
      })

    assert conn.status == 201
    assert %{"id" => channel_id, "operated_by" => "agency"} = body(conn)
    assert [%{"id" => ^channel_id}] = body(as_customer(tanweer, :get, "/v1/channels"))

    assert body(as_customer(tanweer, :patch, "/v1/channels/#{channel_id}", %{label: "Upwork"}))[
             "label"
           ] == "Upwork"

    assert body(
             as_customer(tanweer, :put, "/v1/profiles/#{profile.id}/channels", %{
               channel_ids: [channel_id]
             })
           )["channel_ids"] == [channel_id]

    theirs = channel_fixture(naveed)
    assert as_customer(tanweer, :patch, "/v1/channels/#{theirs.id}", %{label: "x"}).status == 404
    assert as_customer(tanweer, :post, "/v1/channels/#{theirs.id}/archive").status == 404
    assert body(as_customer(tanweer, :post, "/v1/channels/#{channel_id}/archive"))["archived_at"]

    conn =
      as_customer(tanweer, :post, "/v1/profiles/#{profile.id}/documents", %{
        kind: "portfolio",
        label: "Site",
        url: "https://tanweer.dev"
      })

    assert conn.status == 201
    doc = body(conn)["id"]

    assert body(
             as_customer(tanweer, :put, "/v1/profiles/#{profile.id}/default-document", %{
               document_id: doc
             })
           )["default_document_id"] == doc

    conn =
      as_customer(tanweer, :post, "/v1/documents/#{doc}/new-version", %{
        url: "https://tanweer.dev/v2"
      })

    assert conn.status == 201
    assert body(conn)["version_no"] == 2

    assert [%{"id" => _v2}, %{"id" => ^doc}] =
             body(as_customer(tanweer, :get, "/v1/profiles/#{profile.id}/documents"))

    assert body(as_customer(tanweer, :post, "/v1/documents/#{doc}/archive"))["archived_at"]

    other = document_fixture(profile_fixture(naveed))
    assert as_customer(tanweer, :post, "/v1/documents/#{other.id}/archive").status == 404
  end
end
