defmodule Api.RouterTest do
  @moduledoc """
  The contract with the frontend's P0 brief: the one endpoint reaches each
  app's router at its own prefix, every `/info` answers its exact JSON, and
  an unknown path anywhere answers the house error shape.
  """

  use Api.ConnCase, async: true

  @not_found %{
    "error" => %{"code" => "not_found", "message" => "We could not find that.", "details" => %{}}
  }

  describe "GET /info at the root" do
    test "names the service and the build, and nothing else", %{conn: conn} do
      conn = get(conn, "/info")

      assert json_response(conn, 200) == %{"name" => "autoqare", "version" => "0.1.0"}
    end

    test "is never cached: a build number from a proxy is the wrong build", %{conn: conn} do
      assert conn |> get("/info") |> get_resp_header("cache-control") == ["no-store"]
    end
  end

  describe "each app's prefix reaches its own router" do
    test "/team, /client and /ext answer /v1/info as themselves", %{conn: conn} do
      for {path, app} <- [
            {"/team/v1/info", "team"},
            {"/client/v1/info", "client"},
            {"/ext/v1/info", "ext"}
          ] do
        assert conn |> get(path) |> json_response(200) ==
                 %{"app" => app, "api" => "v1", "version" => "0.1.0"}
      end
    end
  end

  test "built like a release, the root has no dev clock, sweeps nor push outbox (AQ-04B §7.6, AQ-08 QP8-16)",
       %{conn: conn} do
    refute Enum.any?(Api.Router.__routes__(), &String.starts_with?(&1.path, "/dev"))

    for {method, path} <- [
          {:get, "/dev/clock"},
          {:post, "/dev/clock"},
          {:post, "/dev/sweeps"},
          {:get, "/dev/push/json"},
          {:delete, "/dev/push/json"}
        ],
        do: assert(dispatch(conn, @endpoint, method, path).status == 404)
  end

  describe "an unknown path" do
    test "under each prefix answers 404 in the house shape", %{conn: conn} do
      for path <- ["/team/v1/nope", "/client/v1/nope", "/ext/v1/nope", "/team/nope", "/ext"] do
        conn = get(conn, path)

        assert conn.status == 404, "#{path} answered #{conn.status}"
        assert json_response(conn, 404) == @not_found
      end
    end

    test "at the root answers the same, whatever the method", %{conn: conn} do
      for {method, path} <- [
            {:get, "/nope"},
            {:get, "/v1/info"},
            {:post, "/info"},
            {:delete, "/board/v1/info"}
          ] do
        conn = dispatch(conn, @endpoint, method, path)

        assert conn.status == 404, "#{method} #{path} answered #{conn.status}"
        assert json_response(conn, 404) == @not_found
      end
    end
  end
end
