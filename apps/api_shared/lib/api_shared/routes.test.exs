defmodule ApiShared.RoutesTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ApiShared.Plugs.App

  # A router shaped like every app's: the shared routes inside its own `/v1`
  # scope, with the app named in the pipeline, and the not-found routes last.
  defmodule SharingRouter do
    use Phoenix.Router

    require ApiShared.Routes

    pipeline :api do
      plug :accepts, ["json"]
      plug App, "sharing"
    end

    ApiShared.Routes.shared_pipelines()

    scope "/v1" do
      pipe_through :api
      ApiShared.Routes.shared_routes()
    end

    ApiShared.Routes.not_found_routes()
  end

  defp call(method, path), do: SharingRouter.call(conn(method, path), SharingRouter.init([]))

  test "the shared routes answer inside the including router, naming its app" do
    conn = call(:get, "/v1/info")

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "app" => "sharing",
             "api" => "v1",
             "version" => "0.1.0"
           }
  end

  test "a path nothing matches answers 404 in the house shape, whatever the method" do
    for method <- [:get, :post, :put, :patch, :delete],
        path <- ["/nope", "/v1/nope", "/", "/v2/info"] do
      conn = call(method, path)

      assert conn.status == 404, "#{method} #{path} answered #{conn.status}"

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "not_found",
                 "message" => "We could not find that.",
                 "details" => %{}
               }
             }
    end
  end
end
