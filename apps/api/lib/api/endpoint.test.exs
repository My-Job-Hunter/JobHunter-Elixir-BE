defmodule Api.EndpointTest do
  @moduledoc """
  The browser calls this from another origin, so a preflight has to be
  answered before the router — and only for the origins on the allowlist.
  `config/test.exs` pins that list, so these assert a value rather than
  whatever dev happens to be set to.
  """

  use Api.ConnCase, async: true

  defp preflight(conn, origin) do
    conn
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "GET")
    |> put_req_header("access-control-request-headers", "authorization")
    |> options("/team/v1/info")
  end

  describe "a preflight OPTIONS" do
    test "from the console's origin is allowed, with the headers the client sends", %{conn: conn} do
      conn = preflight(conn, "http://localhost:5800")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5800"]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "authorization,content-type,accept"
             ]

      assert get_resp_header(conn, "access-control-max-age") == ["86400"]
      assert get_resp_header(conn, "access-control-expose-headers") == ["retry-after"]
    end

    test "from an origin not on the allowlist carries no allow-origin at all", %{conn: conn} do
      conn = preflight(conn, "https://evil.example")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  test "a plain request from an allowed origin is answered with its origin echoed, never *", %{
    conn: conn
  } do
    conn = conn |> put_req_header("origin", "http://localhost:5801") |> get("/team/v1/info")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5801"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "the allowlist is read from config at request time, so runtime.exs can set it" do
    assert Api.Endpoint.cors_origins() == Application.get_env(:api, :cors_origins)
    refute "*" in Api.Endpoint.cors_origins()
  end
end
