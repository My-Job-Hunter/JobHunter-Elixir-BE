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
      assert :aq_authenticated in pipes(method, path), "#{method} #{path} is not authenticated"

      assert :aq_customer in pipes(method, path),
             "#{method} #{path} is not pinned to the customer"

      conn = Router.call(conn(String.to_atom(String.downcase(method)), path), Router.init([]))
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end
  end

  test "every board route of AQ-02 §7.3 is authenticated and pinned; the bell is shared" do
    for {method, path} <- [
          {"GET", "/v1/board"},
          {"GET", "/v1/leads"},
          {"GET", "/v1/leads/l"},
          {"POST", "/v1/leads/l/applied"},
          {"GET", "/v1/suggestions"},
          {"POST", "/v1/tasks"},
          {"GET", "/v1/tasks/t"},
          {"PATCH", "/v1/tasks/t"},
          {"POST", "/v1/tasks/t/done"},
          {"POST", "/v1/tasks/t/reopen"},
          {"POST", "/v1/tasks/t/withdraw"},
          {"POST", "/v1/tasks/t/checklist/i/toggle"},
          {"POST", "/v1/tasks/t/steps/s/toggle"},
          {"POST", "/v1/tasks/t/files"},
          {"GET", "/v1/tasks/t/history"},
          {"GET", "/v1/tasks/t/comments"},
          {"POST", "/v1/tasks/t/comments"},
          {"POST", "/v1/tasks/t/comments/c/replies"},
          {"PATCH", "/v1/task-comments/c"},
          {"DELETE", "/v1/task-comments/c"},
          {"PATCH", "/v1/task-replies/r"},
          {"DELETE", "/v1/task-replies/r"}
        ] do
      assert :aq_customer in pipes(method, path),
             "#{method} #{path} is not pinned to the customer"
    end

    for path <- ["/v1/notifications", "/v1/notifications/count", "/v1/notifications/groups"] do
      assert :aq_authenticated in pipes("GET", path)
    end

    # The portal moves nothing but its own verbs: no staff verb exists here.
    for verb <- ~w(start move hold resume close archive unarchive assignees watch mute) do
      assert Phoenix.Router.route_info(Router, "POST", "/v1/tasks/t/#{verb}", "localhost").plug ==
               ApiShared.NotFoundController
    end
  end

  test "no portal route takes a customer id" do
    for route <- Router.__routes__(), route.path =~ "/v1/" do
      refute route.path =~ "customers/", "#{route.verb} #{route.path} names a customer"
    end
  end
end
