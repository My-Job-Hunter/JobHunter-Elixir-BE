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
          {"GET", "/v1/leads/board"},
          {"POST", "/v1/leads"},
          {"GET", "/v1/leads/l"},
          {"PATCH", "/v1/leads/l"},
          {"POST", "/v1/leads/l/apply"},
          {"POST", "/v1/leads/l/apply-again"},
          {"POST", "/v1/leads/l/move"},
          {"POST", "/v1/leads/l/hold"},
          {"POST", "/v1/leads/l/resume"},
          {"POST", "/v1/leads/l/finish"},
          {"POST", "/v1/leads/l/reopen"},
          {"POST", "/v1/leads/l/archive"},
          {"POST", "/v1/leads/l/unarchive"},
          {"POST", "/v1/leads/l/pin"},
          {"POST", "/v1/leads/l/unpin"},
          {"POST", "/v1/leads/l/assign"},
          {"POST", "/v1/leads/l/cv"},
          {"POST", "/v1/leads/l/pipeline"},
          {"POST", "/v1/leads/l/share-links"},
          {"GET", "/v1/leads/l/share-links"},
          {"GET", "/v1/pipelines"},
          {"GET", "/v1/pipelines/employment"},
          {"PUT", "/v1/pipelines/employment"},
          {"PUT", "/v1/org/settings"},
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
      assert :aq_authenticated in pipes(method, path),
             "#{method} #{path} is not behind :aq_authenticated"

      conn = call(String.downcase(method) |> String.to_atom(), path)
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end
  end

  test "every board route of AQ-02 §7.1 and §7.2 exists and is authenticated" do
    for {method, path} <- [
          {"GET", "/v1/notifications"},
          {"GET", "/v1/notifications/count"},
          {"GET", "/v1/notifications/groups"},
          {"POST", "/v1/notifications/n/read"},
          {"POST", "/v1/notifications/read-all"},
          {"GET", "/v1/board"},
          {"GET", "/v1/tasks/search"},
          {"POST", "/v1/tasks"},
          {"GET", "/v1/tasks/t"},
          {"PATCH", "/v1/tasks/t"},
          {"DELETE", "/v1/tasks/t"},
          {"POST", "/v1/tasks/t/start"},
          {"POST", "/v1/tasks/t/move"},
          {"POST", "/v1/tasks/t/hold"},
          {"POST", "/v1/tasks/t/resume"},
          {"POST", "/v1/tasks/t/done"},
          {"POST", "/v1/tasks/t/reopen"},
          {"POST", "/v1/tasks/t/close"},
          {"POST", "/v1/tasks/t/archive"},
          {"POST", "/v1/tasks/t/unarchive"},
          {"PUT", "/v1/tasks/t/assignees"},
          {"POST", "/v1/tasks/t/watch"},
          {"POST", "/v1/tasks/t/mute"},
          {"GET", "/v1/tasks/t/history"},
          {"POST", "/v1/tasks/t/checklist"},
          {"PATCH", "/v1/tasks/t/checklist/i"},
          {"POST", "/v1/tasks/t/checklist/i/toggle"},
          {"DELETE", "/v1/tasks/t/checklist/i"},
          {"PUT", "/v1/tasks/t/checklist/order"},
          {"POST", "/v1/tasks/t/steps"},
          {"PATCH", "/v1/tasks/t/steps/s"},
          {"POST", "/v1/tasks/t/steps/s/toggle"},
          {"POST", "/v1/tasks/t/steps/s/nudge"},
          {"DELETE", "/v1/tasks/t/steps/s"},
          {"PUT", "/v1/tasks/t/steps/order"},
          {"POST", "/v1/tasks/t/links"},
          {"DELETE", "/v1/tasks/t/links/l"},
          {"POST", "/v1/tasks/t/relations"},
          {"DELETE", "/v1/tasks/t/relations/r"},
          {"POST", "/v1/tasks/t/files"},
          {"DELETE", "/v1/tasks/t/files/m"},
          {"GET", "/v1/tasks/t/comments"},
          {"POST", "/v1/tasks/t/comments"},
          {"POST", "/v1/tasks/t/comments/c/replies"},
          {"PATCH", "/v1/task-comments/c"},
          {"DELETE", "/v1/task-comments/c"},
          {"PATCH", "/v1/task-replies/r"},
          {"DELETE", "/v1/task-replies/r"},
          {"GET", "/v1/me/stages"},
          {"POST", "/v1/me/stages"},
          {"PATCH", "/v1/me/stages/s"},
          {"DELETE", "/v1/me/stages/s"},
          {"PUT", "/v1/me/stages/order"}
        ] do
      assert :aq_authenticated in pipes(method, path), "#{method} #{path} is not authenticated"
      conn = call(String.downcase(method) |> String.to_atom(), path)
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end

    assert %{plug_opts: :search} =
             Phoenix.Router.route_info(Router, "GET", "/v1/tasks/search", "localhost")
  end

  test "every job pool route of AQ-03 §7 exists and is authenticated" do
    for {method, path} <- [
          {"GET", "/v1/jobs"},
          {"POST", "/v1/jobs/check"},
          {"POST", "/v1/jobs"},
          {"GET", "/v1/jobs/j"},
          {"PATCH", "/v1/jobs/j"},
          {"PUT", "/v1/jobs/j/platform-details"},
          {"POST", "/v1/jobs/j/close"},
          {"POST", "/v1/jobs/j/reopen"},
          {"POST", "/v1/jobs/j/archive"},
          {"POST", "/v1/jobs/j/unarchive"},
          {"POST", "/v1/jobs/j/merge"},
          {"GET", "/v1/jobs/j/suggestions"},
          {"POST", "/v1/jobs/j/dismissals"},
          {"DELETE", "/v1/jobs/j/dismissals/p"},
          {"GET", "/v1/companies"},
          {"POST", "/v1/companies"},
          {"GET", "/v1/companies/c"},
          {"PATCH", "/v1/companies/c"}
        ] do
      assert :aq_authenticated in pipes(method, path), "#{method} #{path} is not authenticated"
      conn = call(String.downcase(method) |> String.to_atom(), path)
      assert conn.status == 401, "#{method} #{path} without a token answered #{conn.status}"
    end
  end

  test "the rate limits of §6 are wired on their routes" do
    assert :aq_login_limit in pipes("POST", "/v1/auth/login")
    assert :aq_login_limit in pipes("POST", "/v1/auth/google")
    assert :aq_forgot_limit in pipes("POST", "/v1/auth/password/forgot")
    assert :aq_invitation_limit in pipes("GET", "/v1/auth/invitations/XX-XXXX")
    assert :aq_invitation_limit in pipes("POST", "/v1/auth/invitations/XX-XXXX/accept")
    assert :aq_maybe_authenticated in pipes("POST", "/v1/auth/invitations/XX-XXXX/accept")
    refute :aq_login_limit in pipes("POST", "/v1/auth/refresh")
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
