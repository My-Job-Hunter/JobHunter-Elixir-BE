defmodule ApiShared.MediaControllerTest do
  use ApiShared.SharedCase, async: true

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> "JFIF and some bytes"

  setup do
    org = organisation_fixture()
    user = member_fixture(team_fixture(org), :member)
    %{user: user}
  end

  defp declare(user, params) do
    request(build(:post, "/v1/media", params) |> authed(user))
  end

  defp put_blob(user, id, bytes) do
    :put
    |> build("/v1/media/#{id}/blob")
    |> put_req_header("content-type", "application/octet-stream")
    |> Map.put(:body_params, %{})
    |> then(&%{&1 | adapter: {Plug.Adapters.Test.Conn, %{elem(&1.adapter, 1) | req_body: bytes}}})
    |> authed(user)
    |> request()
  end

  test "the three steps, then a signed read", %{user: user} do
    conn =
      declare(user, %{
        media_kind: "photo",
        content_type: "image/jpeg",
        byte_count: byte_size(@jpeg),
        original_filename: "me.jpg"
      })

    assert conn.status == 201

    assert %{
             "id" => id,
             "upload" => %{"url" => url, "method" => "PUT", "headers" => %{}},
             "uploaded_at" => nil,
             "url" => link
           } = body(conn)

    assert url == "/v1/media/#{id}/blob"

    assert put_blob(user, id, @jpeg).status == 204

    conn = request(build(:post, "/v1/media/#{id}/confirm", %{width_px: 10}) |> authed(user))
    assert conn.status == 200
    assert body(conn)["uploaded_at"]
    assert body(conn)["width_px"] == 10

    read = request(build(:get, "/v1" <> link))
    assert read.status == 200
    assert read.resp_body == @jpeg
    assert get_resp_header(read, "content-type") == ["image/jpeg"]
    assert get_resp_header(read, "cache-control") == ["private, max-age=3600"]
    assert get_resp_header(read, "x-content-type-options") == ["nosniff"]

    assert request(build(:get, "/v1/media/#{id}")).status == 404
    assert request(build(:get, "/v1/media/#{id}?t=forged")).status == 404
  end

  test "mismatch, too large and not allowed answer their codes", %{user: user} do
    conn =
      declare(user, %{media_kind: "document", content_type: "application/pdf", byte_count: 20})

    id = body(conn)["id"]
    mismatch = put_blob(user, id, @jpeg)
    assert mismatch.status == 422
    assert body(mismatch)["error"]["code"] == "file_mismatch"

    big = declare(user, %{media_kind: "photo", content_type: "image/jpeg", byte_count: 9_000_000})
    assert big.status == 413
    assert body(big)["error"]["code"] == "file_too_large"
    assert body(big)["error"]["details"]["max_bytes"] == 5_000

    svg = declare(user, %{media_kind: "photo", content_type: "image/svg+xml", byte_count: 20})
    assert svg.status == 415
    assert body(svg)["error"]["code"] == "file_type_not_allowed"

    assert declare(user, %{media_kind: "photo", byte_count: 20}).status == 422
  end

  test "without a token the upload routes are 401; the read is by link only" do
    assert request(build(:post, "/v1/media", %{})).status == 401
    assert request(build(:put, "/v1/media/#{Ecto.UUID.generate()}/blob")).status == 401
    assert request(build(:get, "/v1/media/#{Ecto.UUID.generate()}")).status == 404
  end
end
