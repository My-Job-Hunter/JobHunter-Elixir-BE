defmodule ApiTeam.DocumentControllerTest do
  use ApiTeam.TeamCase, async: true

  alias Core.Auth.Guardian

  @pdf "%PDF-1.4 a small but genuine-looking file"

  setup do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    member = member_fixture(backend, :member)
    tanweer = customer_fixture(org, [backend])
    imran = customer_fixture(org, [frontend])
    profile = profile_fixture(tanweer, title: "Golang backend")
    %{member: member, tanweer: tanweer, imran: imran, profile: profile}
  end

  defp upload(user, bytes) do
    conn =
      call(user, :post, "/v1/media", %{
        media_kind: "document",
        content_type: "application/pdf",
        byte_count: byte_size(bytes),
        original_filename: "cv.pdf"
      })

    assert conn.status == 201
    id = body(conn)["id"]

    blob =
      :put
      |> conn("/v1/media/#{id}/blob", bytes)
      |> put_req_header("content-type", "application/pdf")
      |> authed(user)
      |> ApiTeam.Router.call(ApiTeam.Router.init([]))

    assert blob.status == 204
    assert call(user, :post, "/v1/media/#{id}/confirm", %{page_count: 2}).status == 200
    id
  end

  defp authed(conn, user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    put_req_header(conn, "authorization", "Bearer " <> tokens.access_token)
  end

  test "a CV through the three-step upload, a new version, the default, a link document, archive",
       %{
         member: member,
         profile: profile,
         imran: imran
       } do
    media_id = upload(member, @pdf)

    conn =
      call(member, :post, "/v1/profiles/#{profile.id}/documents", %{
        kind: "cv",
        label: "Golang",
        media_id: media_id
      })

    assert conn.status == 201

    assert %{
             "id" => v1,
             "kind" => "cv",
             "label" => "Golang",
             "version_no" => 1,
             "supersedes_document_id" => nil,
             "url" => nil,
             "is_default" => false,
             "media" => %{
               "id" => ^media_id,
               "content_type" => "application/pdf",
               "original_filename" => "cv.pdf",
               "url" => link
             }
           } = body(conn)

    assert String.starts_with?(link, "/media/#{media_id}?t=")

    # One source, not two, not none; a file somebody else uploaded is not found.
    assert call(member, :post, "/v1/profiles/#{profile.id}/documents", %{kind: "cv", label: "x"}).status ==
             422

    assert call(member, :post, "/v1/profiles/#{profile.id}/documents", %{
             kind: "cv",
             label: "x",
             media_id: media_id,
             url: "https://a.b"
           }).status == 422

    assert call(member, :post, "/v1/profiles/#{profile.id}/documents", %{
             kind: "cv",
             label: "x",
             media_id: Ecto.UUID.generate()
           }).status == 404

    conn = call(member, :put, "/v1/profiles/#{profile.id}/default-document", %{document_id: v1})
    assert conn.status == 200
    assert body(conn)["default_document_id"] == v1

    conn =
      call(member, :post, "/v1/documents/#{v1}/new-version", %{
        media_id: upload(member, @pdf <> " v2")
      })

    assert conn.status == 201

    assert %{"id" => v2, "version_no" => 2, "supersedes_document_id" => ^v1, "is_default" => true} =
             body(conn)

    conn = call(member, :get, "/v1/profiles/#{profile.id}/documents")
    assert Enum.map(body(conn), & &1["version_no"]) == [2, 1]
    assert Enum.find(body(conn), &(&1["id"] == v1))["is_default"] == false

    conn =
      call(member, :post, "/v1/profiles/#{profile.id}/documents", %{
        kind: "portfolio",
        label: "Site",
        url: "https://tanweer.dev"
      })

    assert conn.status == 201
    assert %{"id" => site, "media" => nil, "url" => "https://tanweer.dev"} = body(conn)

    assert call(member, :post, "/v1/profiles/#{profile.id}/documents", %{
             kind: "portfolio",
             label: "Bad",
             url: "ftp://x"
           }).status == 422

    assert body(call(member, :patch, "/v1/documents/#{site}", %{label: "Website"}))["label"] ==
             "Website"

    assert call(member, :patch, "/v1/documents/#{v2}", %{url: "https://x.y"}).status == 422

    assert body(call(member, :post, "/v1/documents/#{v1}/archive"))["archived_at"]

    assert Enum.map(
             body(call(member, :get, "/v1/profiles/#{profile.id}/documents")),
             & &1["id"]
           )
           |> Enum.sort() ==
             Enum.sort([v2, site])

    theirs = profile_fixture(imran)
    assert call(member, :get, "/v1/profiles/#{theirs.id}/documents").status == 404

    assert call(member, :post, "/v1/profiles/#{theirs.id}/documents", %{
             kind: "cv",
             label: "x",
             url: "https://a.b"
           }).status == 404

    assert call(member, :put, "/v1/profiles/#{profile.id}/default-document", %{
             document_id: document_fixture(theirs).id
           }).status == 404
  end
end
