defmodule ApiTeam.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ApiTeam.Router

  defp call(method, path), do: Router.call(conn(method, path), Router.init([]))

  defp pipes(method, path) do
    %{pipe_through: pipes} = Phoenix.Router.route_info(Router, method, path, "localhost")
    pipes
  end

  test "v1/info answers as team" do
    conn = call(:get, "/v1/info")
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "app" => "team",
             "api" => "v1",
             "version" => "0.1.0"
           }
  end

  test "v1 answers are never cached" do
    assert Plug.Conn.get_resp_header(call(:get, "/v1/info"), "cache-control") == ["no-store"]
  end

  test "an unknown path answers 404 not_found" do
    conn = call(:get, "/v1/nope")
    assert conn.status == 404
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(conn.resp_body)
  end

  test "every console route of §6.2 exists and is authenticated" do
    for {method, path} <- [
          {"GET", "/v1/org"},
          {"PUT", "/v1/org/settings"},
          {"GET", "/v1/org/admins"},
          {"POST", "/v1/org/admins"},
          {"DELETE", "/v1/org/admins/u"},
          {"GET", "/v1/org/audit"},
          {"GET", "/v1/teams"},
          {"POST", "/v1/teams"},
          {"GET", "/v1/teams/t"},
          {"PATCH", "/v1/teams/t"},
          {"POST", "/v1/teams/t/archive"},
          {"GET", "/v1/teams/t/settings"},
          {"PUT", "/v1/teams/t/settings"},
          {"GET", "/v1/teams/t/members"},
          {"POST", "/v1/teams/t/members/u/role"},
          {"DELETE", "/v1/teams/t/members/u"},
          {"GET", "/v1/invitations"},
          {"POST", "/v1/invitations"},
          {"POST", "/v1/invitations/i/revoke"},
          {"POST", "/v1/invitations/i/resend"},
          {"GET", "/v1/people"},
          {"GET", "/v1/customers"},
          {"POST", "/v1/customers"},
          {"GET", "/v1/customers/c"},
          {"PATCH", "/v1/customers/c"},
          {"POST", "/v1/customers/c/status"},
          {"POST", "/v1/customers/c/teams"},
          {"DELETE", "/v1/customers/c/teams/t"},
          {"POST", "/v1/customers/c/invite"},
          {"GET", "/v1/customers/c/notes"},
          {"POST", "/v1/customers/c/notes"},
          {"PATCH", "/v1/notes/n"},
          {"DELETE", "/v1/notes/n"},
          {"GET", "/v1/customers/c/profiles"},
          {"POST", "/v1/customers/c/profiles"},
          {"GET", "/v1/profiles/p"},
          {"PATCH", "/v1/profiles/p"},
          {"POST", "/v1/profiles/p/archive"},
          {"PUT", "/v1/profiles/p/owners"},
          {"PUT", "/v1/profiles/p/skills"},
          {"PUT", "/v1/profiles/p/channels"},
          {"GET", "/v1/customers/c/channels"},
          {"POST", "/v1/customers/c/channels"},
          {"PATCH", "/v1/channels/ch"},
          {"POST", "/v1/channels/ch/archive"},
          {"GET", "/v1/profiles/p/documents"},
          {"POST", "/v1/profiles/p/documents"},
          {"PATCH", "/v1/documents/d"},
          {"POST", "/v1/documents/d/archive"},
          {"POST", "/v1/documents/d/new-version"},
          {"PUT", "/v1/profiles/p/default-document"},
          {"GET", "/v1/skills"},
          {"POST", "/v1/skills"},
          {"POST", "/v1/skills/s/archive"},
          {"GET", "/v1/me"},
          {"POST", "/v1/auth/logout"}
        ] do
      assert :jh_authenticated in pipes(method, path),
             "#{method} #{path} is not behind :jh_authenticated"

      conn = call(String.downcase(method) |> String.to_atom(), path)
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end
  end

  test "the rate limits of §6 are wired on their routes" do
    assert :jh_login_limit in pipes("POST", "/v1/auth/login")
    assert :jh_login_limit in pipes("POST", "/v1/auth/google")
    assert :jh_forgot_limit in pipes("POST", "/v1/auth/password/forgot")
    assert :jh_invitation_limit in pipes("GET", "/v1/auth/invitations/XX-XXXX")
    assert :jh_invitation_limit in pipes("POST", "/v1/auth/invitations/XX-XXXX/accept")
    assert :jh_maybe_authenticated in pipes("POST", "/v1/auth/invitations/XX-XXXX/accept")
    refute :jh_login_limit in pipes("POST", "/v1/auth/refresh")
  end
end

defmodule ApiTeam.RouterRateLimitTest do
  @moduledoc """
  The one place a configured limit is seen to bite on a real route. The
  sign-in reads the database, so this needs the sandbox; `async: false`
  because it swaps global config.
  """

  use ApiTeam.TeamCase, async: false

  alias ApiTeam.Router

  test "ten sign-ins a minute per address, then 429 in the house shape" do
    original = Application.get_env(:core, Core.Plugs.RateLimit)
    Application.put_env(:core, Core.Plugs.RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:core, Core.Plugs.RateLimit, original) end)
    ip = "198.51.100.#{System.unique_integer([:positive]) |> rem(250)}"

    conns =
      for _n <- 1..11 do
        :post
        |> conn("/v1/auth/login", %{"email" => "x@example.com", "password" => "whatever it is"})
        |> put_req_header("x-forwarded-for", ip)
        |> Router.call(Router.init([]))
      end

    assert Enum.map(Enum.take(conns, 10), & &1.status) == List.duplicate(401, 10)
    last = List.last(conns)
    assert last.status == 429
    assert body(last)["error"]["code"] == "rate_limited"
  end
end
