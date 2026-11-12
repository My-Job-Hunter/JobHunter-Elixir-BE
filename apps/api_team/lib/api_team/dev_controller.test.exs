defmodule ApiTeam.DevControllerTest do
  @moduledoc """
  The dev clock (AQ-04B §7.6, QP4b-1). **A release has neither route**: the
  routes compile in only with `config :api, dev_routes: true`, which
  `config/dev.exs` alone sets — so here, built like a release, the console's
  router has no `/v1/dev/clock` nor `/v1/dev/sweeps` (`Api.RouterTest` checks the
  root's), and the paths are the house
  404. The controller itself is exercised directly, as a dev server runs it.
  """

  use ApiTeam.TeamCase, async: false

  alias Core.Clock
  alias Notifire.Push.Outbox

  @root Path.expand("../../../..", __DIR__)

  setup do
    previous = Application.get_env(:core, :dev_clock)

    on_exit(fn ->
      Application.put_env(:core, :dev_clock, true)
      Clock.set_offset_days(0)
      Application.put_env(:core, :dev_clock, previous)
    end)
  end

  test "the push outbox (AQ-08 QP8-16): newest first, the payload's four keys; the delete empties it" do
    conn =
      Plug.Test.conn(:get, "/dev/push/json")
      |> Phoenix.Controller.put_format("json")

    Outbox.clear()

    for n <- 1..2 do
      Outbox.record(%{
        at: ~U[2026-11-12 06:00:00Z],
        user_id: "u#{n}",
        app: :team,
        endpoint: "https://push.example/#{n}",
        payload: %{title: "T#{n}", body: nil, tag: "n#{n}", url: "/notifications?n=n#{n}"}
      })
    end

    assert %{"items" => [%{"user_id" => "u2", "app" => "team", "payload" => payload}, _first]} =
             Jason.decode!(ApiTeam.DevController.push_outbox(conn, %{}).resp_body)

    assert payload == %{
             "title" => "T2",
             "body" => nil,
             "tag" => "n2",
             "url" => "/notifications?n=n2"
           }

    assert ApiTeam.DevController.clear_push_outbox(conn, %{}).status == 204

    assert Jason.decode!(ApiTeam.DevController.push_outbox(conn, %{}).resp_body) == %{
             "items" => []
           }
  end

  test "built like a release: no dev route in either router, and the paths answer 404" do
    refute Application.get_env(:api, :dev_routes, false)

    refute Enum.any?(ApiTeam.Router.__routes__(), &(&1.path =~ "/dev/"))

    user = user_fixture()

    for {method, path} <- [
          {:post, "/v1/dev/clock"},
          {:get, "/v1/dev/clock"},
          {:post, "/v1/dev/sweeps"}
        ] do
      conn = call(user, method, path, %{days: 3})
      assert conn.status == 404 and code(conn) == "not_found"
    end

    # Only dev.exs turns the routes and the dev clock on.
    for file <- ~w(config.exs prod.exs runtime.exs test.exs) do
      source = File.read!(Path.join([@root, "config", file]))
      refute source =~ "dev_routes: true", "#{file} turns the dev routes on"
      refute source =~ "dev_clock: true", "#{file} turns the dev clock on"
    end

    assert File.read!(Path.join([@root, "config", "dev.exs"])) =~ "dev_clock: true"
  end

  test "on a dev server: {days} moves now for every reader; 0 resets; sweeps answer in order" do
    Application.put_env(:core, :dev_clock, true)

    conn =
      Plug.Test.conn(:post, "/v1/dev/clock")
      |> Plug.Conn.assign(:scope, scope_for(user_fixture()))
      |> Phoenix.Controller.put_format("json")

    moved = ApiTeam.DevController.set_clock(conn, %{"days" => 92})
    assert %{"days" => 92, "offset_days" => 92, "now" => now} = Jason.decode!(moved.resp_body)
    {:ok, now, 0} = DateTime.from_iso8601(now)
    assert DateTime.diff(now, DateTime.utc_now(), :day) in [91, 92]
    assert Clock.offset_days() == 92

    assert %{"days" => 92} =
             Jason.decode!(ApiTeam.DevController.clock(conn, %{}).resp_body)

    swept = Jason.decode!(ApiTeam.DevController.sweeps(conn, %{}).resp_body)

    assert Enum.map(swept["sweeps"], & &1["name"]) ==
             ~w(follow_up_scan warn_sweep archive_sweep purge_sweep meeting_reminders
                approval_reminders approval_expiry)

    # AQ-08 §11.4: the digest scan and, last, the delivery sweep.
    assert %{"digests" => digests, "delivery" => %{"sent" => _, "skipped" => _, "failed" => _}} =
             swept

    assert is_integer(digests)

    assert %{"days" => 0} =
             Jason.decode!(ApiTeam.DevController.set_clock(conn, %{"days" => "0"}).resp_body)

    assert ApiTeam.DevController.set_clock(conn, %{"days" => -1}) ==
             {:error, {:invalid, %{"days" => ["is a whole number of days, 0 to 3650"]}}}

    assert ApiTeam.DevController.set_clock(conn, %{}) == {:error, {:missing, [:days]}}
  end
end
