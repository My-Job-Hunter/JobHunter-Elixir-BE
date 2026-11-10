defmodule ApiExt.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defp call(method, path), do: ApiExt.Router.call(conn(method, path), ApiExt.Router.init([]))

  test "v1/info answers as ext" do
    conn = call(:get, "/v1/info")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"app" => "ext", "api" => "v1", "version" => "0.1.0"}
  end

  test "an unknown path answers 404 not_found" do
    conn = call(:get, "/v1/nope")

    assert conn.status == 404
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(conn.resp_body)
  end
end
