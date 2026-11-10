defmodule ApiTeam.ChannelControllerTest do
  use ApiTeam.TeamCase, async: true

  setup do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    member = member_fixture(backend, :member)
    tanweer = customer_fixture(org, [backend])
    imran = customer_fixture(org, [frontend])
    %{member: member, tanweer: tanweer, imran: imran}
  end

  test "a member has full run of a customer's channels; the handle is normalised; no credential field",
       %{
         member: member,
         tanweer: tanweer,
         imran: imran
       } do
    conn =
      call(member, :post, "/v1/customers/#{tanweer.id}/channels", %{
        kind: "linkedin",
        label: "LinkedIn",
        handle: "https://LinkedIn.com/in/Tanweer/",
        operated_by: "agency",
        password: "should-be-ignored"
      })

    assert conn.status == 201

    assert %{
             "id" => id,
             "kind" => "linkedin",
             "handle" => "https://LinkedIn.com/in/Tanweer/",
             "handle_normalized" => "https://linkedin.com/in/tanweer",
             "operated_by" => "agency",
             "listens_via" => "none",
             "status" => "active",
             "profile_ids" => []
           } = body(conn)

    refute Map.has_key?(body(conn), "password")

    # The same handle in another case is the same channel.
    assert call(member, :post, "/v1/customers/#{tanweer.id}/channels", %{
             kind: "linkedin",
             handle: "https://linkedin.com/in/tanweer"
           }).status == 422

    assert call(member, :post, "/v1/customers/#{tanweer.id}/channels", %{
             kind: "myspace",
             handle: "x"
           }).status == 422

    assert call(member, :post, "/v1/customers/#{imran.id}/channels", %{
             kind: "email",
             handle: "a@b.co"
           }).status == 404

    assert [%{"id" => ^id}] =
             body(call(member, :get, "/v1/customers/#{tanweer.id}/channels"))

    assert call(member, :get, "/v1/customers/#{imran.id}/channels").status == 404

    conn = call(member, :patch, "/v1/channels/#{id}", %{status: "paused", label: "Main LinkedIn"})
    assert body(conn)["status"] == "paused"
    assert body(conn)["label"] == "Main LinkedIn"

    conn = call(member, :post, "/v1/channels/#{id}/archive")
    assert body(conn)["archived_at"]
    assert body(call(member, :get, "/v1/customers/#{tanweer.id}/channels")) == []

    # Archived, the handle is free again.
    assert call(member, :post, "/v1/customers/#{tanweer.id}/channels", %{
             kind: "linkedin",
             handle: "https://linkedin.com/in/tanweer"
           }).status == 201

    theirs = channel_fixture(imran)
    assert call(member, :patch, "/v1/channels/#{theirs.id}", %{label: "x"}).status == 404
  end
end
