defmodule ApiExt.SessionControllerTest do
  @moduledoc """
  AQ-05 §7, §11.4 (P5.1) through the router: the code works once (201,
  then P1's 410 `token_invalid`), the device and its tokens, tokens that
  stay in their own app, the refresh that keeps the device, and
  *Disconnect* (204) killing the refresh.
  """

  use ApiExt.ExtCase, async: true

  alias Core.Auth.Guardian
  alias Core.Extension

  @agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"

  setup do
    c = board_cast_fixture()
    {:ok, %{code: code}} = Extension.connect_code(scope_for(c.fiza), DateTime.utc_now())
    Map.put(c, :code, code)
  end

  defp exchange(code) do
    call(nil, :post, "/v1/session", %{"code" => code, "extension_version" => "0.1.0"}, [
      {"user-agent", @agent}
    ])
  end

  test "the code → 201 {access_token, refresh_token, device, me}", c do
    conn = exchange(c.code)
    assert conn.status == 201

    answer = body(conn)
    assert Map.keys(answer) |> Enum.sort() == ~w(access_token device me refresh_token)

    assert Map.keys(answer["device"]) |> Enum.sort() ==
             ~w(connected_at current extension_version id last_seen_at name person)

    assert answer["device"]["name"] == "Chrome on macOS"
    assert answer["device"]["current"] == true
    assert answer["device"]["person"]["name"] == "Fiza"
    assert answer["me"]["user"]["id"] == c.fiza.id

    {:ok, claims} = Guardian.decode_and_verify(answer["access_token"])
    assert claims["sid"] == answer["device"]["id"]
    assert claims["dev"]["app"] == "ext"
    assert claims["dev"]["agent"] == @agent
  end

  test "the same code again, a nonsense one and none: 410 token_invalid", c do
    assert exchange(c.code).status == 201

    for code <- [c.code, "nonsense", nil] do
      conn = exchange(code)
      assert conn.status == 410
      assert code(conn) == "token_invalid"
    end
  end

  test "the device token works on /ext; a console token there is 401", c do
    answer = body(exchange(c.code))

    me = call(answer["access_token"], :get, "/v1/me")
    assert me.status == 200
    assert body(me)["user"]["id"] == c.fiza.id
    assert call(answer["access_token"], :get, "/v1/notifications/count").status == 200

    {:ok, console} = Guardian.tokens_for(c.fiza, %{"dev" => %{"app" => "team"}})
    conn = call(console.access_token, :get, "/v1/me")
    assert conn.status == 401 and code(conn) == "unauthenticated"

    # A pair minted with no app at all (P1's sign-in before P5) is no device's either.
    {:ok, bare} = Guardian.tokens_for(c.fiza)
    assert call(bare.access_token, :get, "/v1/me").status == 401
  end

  test "a refresh keeps the device; a console refresh token is refused here", c do
    answer = body(exchange(c.code))

    conn = call(nil, :post, "/v1/auth/refresh", %{"refresh_token" => answer["refresh_token"]})
    assert conn.status == 200
    {:ok, claims} = Guardian.decode_and_verify(body(conn)["access_token"])
    assert claims["sid"] == answer["device"]["id"]

    {:ok, console} = Guardian.tokens_for(c.fiza, %{"dev" => %{"app" => "team"}})
    conn = call(nil, :post, "/v1/auth/refresh", %{"refresh_token" => console.refresh_token})
    assert conn.status == 401 and code(conn) == "invalid_refresh_token"
  end

  test "DELETE /session: 204, and the next refresh fails, and so does the access token", c do
    answer = body(exchange(c.code))

    assert call(answer["access_token"], :delete, "/v1/session").status == 204

    conn = call(nil, :post, "/v1/auth/refresh", %{"refresh_token" => answer["refresh_token"]})
    assert conn.status == 401 and code(conn) == "invalid_refresh_token"
    assert call(answer["access_token"], :get, "/v1/me").status == 401

    device = Data.Devices.get(c.org.id, answer["device"]["id"])
    assert device.revoked_at
  end

  test "auth/logout on /ext is Disconnect too", c do
    answer = body(exchange(c.code))

    assert call(answer["access_token"], :post, "/v1/auth/logout").status == 204
    assert Data.Devices.get(c.org.id, answer["device"]["id"]).revoked_at
  end

  test "a device disconnected elsewhere stops at its next request", c do
    {device, tokens} = connected(c.fiza)
    {:ok, _} = Extension.disconnect(scope_for(c.dawud), device.id, DateTime.utc_now())

    assert call(tokens.access_token, :get, "/v1/me").status == 401
  end

  test "a device of someone who is no longer staff: 401", c do
    {_device, tokens} = connected(c.muaz)

    {:ok, _left} =
      c.backend.id
      |> Data.Teams.get_open_member(c.muaz.id)
      |> Data.Teams.leave(DateTime.utc_now())

    assert call(tokens.access_token, :get, "/v1/context", %{"site" => "linkedin"}).status == 401
  end
end
