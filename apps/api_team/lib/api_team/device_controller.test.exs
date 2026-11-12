defmodule ApiTeam.DeviceControllerTest do
  @moduledoc """
  AQ-05 §11.2 (P5.1): the console's connect code (201 `{code,
  expires_at}`), Account › Extension's devices and Settings › Extension's
  every device, *Disconnect* (204), and a device token refused on `/team`.
  """

  use ApiTeam.TeamCase, async: true

  alias Core.Auth.Guardian

  setup do
    board_cast_fixture()
  end

  defp device_token(user) do
    device = device_fixture(scope_for(user))
    {:ok, tokens} = Guardian.tokens_for(user, %{"sid" => device.id, "dev" => %{"app" => "ext"}})
    {device, tokens}
  end

  test "POST /devices/connect-codes {}: 201 {code, expires_at}, any staff member", c do
    conn = call(c.fiza, :post, "/v1/devices/connect-codes", %{})
    assert conn.status == 201
    assert %{"code" => code, "expires_at" => at} = body(conn)
    assert code =~ ~r/^[A-Za-z0-9_-]{32}$/
    assert {:ok, _at, 0} = DateTime.from_iso8601(at)

    # Tanweer's account is a customer's: it cannot connect.
    tanweer = Data.Accounts.get_user(c.tanweer.user_id)
    assert call(tanweer, :post, "/v1/devices/connect-codes", %{}).status == 404
  end

  test "GET /devices: the caller's live devices, current false; ?all=true the system admin's",
       c do
    {mine, _tokens} = device_token(c.fiza)
    {theirs, _tokens} = device_token(c.hira)
    revoked = device_fixture(scope_for(c.fiza))
    {:ok, _} = Data.Devices.revoke(revoked, DateTime.utc_now(), c.fiza.id)

    conn = call(c.fiza, :get, "/v1/devices")
    assert conn.status == 200
    assert [device] = body(conn)
    assert device["id"] == mine.id
    assert device["current"] == false
    assert device["person"] == %{"user_id" => c.fiza.id, "name" => "Fiza", "photo_url" => nil}

    assert Map.keys(device) |> Enum.sort() ==
             ~w(connected_at current extension_version id last_seen_at name person)

    assert call(c.fiza, :get, "/v1/devices", %{"all" => "true"}).status == 404

    all = body(call(c.dawud, :get, "/v1/devices", %{"all" => "true"}))
    assert Enum.sort(Enum.map(all, & &1["id"])) == Enum.sort([mine.id, theirs.id])
  end

  test "DELETE /devices/:id: the owner or the system admin, 204; anyone else 404", c do
    {device, tokens} = device_token(c.fiza)

    assert call(c.hira, :delete, "/v1/devices/#{device.id}").status == 404
    assert call(c.fiza, :delete, "/v1/devices/#{device.id}").status == 204
    assert call(c.fiza, :delete, "/v1/devices/#{device.id}").status == 404

    assert Guardian.exchange_refresh_token(tokens.refresh_token, "ext") ==
             {:error, :invalid_refresh_token}

    {other, _tokens} = device_token(c.muaz)
    assert call(c.dawud, :delete, "/v1/devices/#{other.id}").status == 204
  end

  test "a device token on /team is 401, and so is its refresh", c do
    {_device, tokens} = device_token(c.fiza)

    conn =
      :get
      |> Plug.Test.conn("/v1/me")
      |> put_req_header("authorization", "Bearer " <> tokens.access_token)
      |> ApiTeam.Router.call(ApiTeam.Router.init([]))

    assert conn.status == 401
    assert body(conn)["error"]["code"] == "unauthenticated"

    conn =
      :post
      |> Plug.Test.conn("/v1/auth/refresh", %{"refresh_token" => tokens.refresh_token})
      |> ApiTeam.Router.call(ApiTeam.Router.init([]))

    assert conn.status == 401
    assert body(conn)["error"]["code"] == "invalid_refresh_token"
  end
end
