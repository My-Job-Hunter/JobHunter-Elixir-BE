defmodule ApiClient.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  defp call(method, path),
    do: ApiClient.Router.call(conn(method, path), ApiClient.Router.init([]))

  test "v1/info answers as client" do
    conn = call(:get, "/v1/info")

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "app" => "client",
             "api" => "v1",
             "version" => "0.1.0"
           }
  end

  test "an unknown path answers 404 not_found" do
    conn = call(:get, "/v1/nope")

    assert conn.status == 404
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(conn.resp_body)
  end
end

defmodule ApiClient.RouterPipelineTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ApiClient.Router

  defp pipes(method, path) do
    %{pipe_through: pipes} = Phoenix.Router.route_info(Router, method, path, "localhost")
    pipes
  end

  test "every portal route of §6.3 is authenticated and pinned to the customer" do
    for {method, path} <- [
          {"GET", "/v1/customer"},
          {"PATCH", "/v1/customer"},
          {"GET", "/v1/team"},
          {"GET", "/v1/profiles"},
          {"GET", "/v1/profiles/p"},
          {"PATCH", "/v1/profiles/p"},
          {"PUT", "/v1/profiles/p/skills"},
          {"PUT", "/v1/profiles/p/channels"},
          {"GET", "/v1/channels"},
          {"POST", "/v1/channels"},
          {"PATCH", "/v1/channels/c"},
          {"POST", "/v1/channels/c/archive"},
          {"GET", "/v1/profiles/p/documents"},
          {"POST", "/v1/profiles/p/documents"},
          {"POST", "/v1/documents/d/new-version"},
          {"POST", "/v1/documents/d/archive"},
          {"PUT", "/v1/profiles/p/default-document"},
          {"GET", "/v1/skills"}
        ] do
      assert :jh_authenticated in pipes(method, path), "#{method} #{path} is not authenticated"

      assert :jh_customer in pipes(method, path),
             "#{method} #{path} is not pinned to the customer"

      conn = Router.call(conn(String.to_atom(String.downcase(method)), path), Router.init([]))
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end
  end

  test "no portal route takes a customer id" do
    for route <- Router.__routes__(), route.path =~ "/v1/" do
      refute route.path =~ "customers/", "#{route.verb} #{route.path} names a customer"
    end
  end
end
