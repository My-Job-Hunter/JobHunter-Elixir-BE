defmodule ApiTeam.ExtensionControllerTest do
  @moduledoc """
  AQ-05 §11.2 (P5.5): Settings › Extension — the health page and the
  configs list — for the system admin, 404 for anyone else.
  """

  use ApiTeam.TeamCase, async: true

  alias Core.Extension.Health

  setup do
    board_cast_fixture()
  end

  test "GET /extension/health: §11.3's health", c do
    device_fixture(scope_for(c.fiza))
    config = config_fixture(:linkedin)

    :ok =
      Health.report(
        %{scope_for(c.fiza) | via: :extension},
        %{
          "extension_version" => "0.1.0",
          "misses" => [
            %{
              "site" => "linkedin",
              "page_kind" => "job",
              "selector_key" => "title",
              "config_version" => config.version,
              "count" => 14
            }
          ]
        },
        DateTime.utc_now()
      )

    conn = call(c.dawud, :get, "/v1/extension/health")
    assert conn.status == 200
    health = body(conn)

    assert Map.keys(health) |> Enum.sort() == ~w(devices sites)
    assert [linkedin, upwork] = health["sites"]
    assert Map.keys(linkedin) |> Enum.sort() == ~w(config last_capture_at misses site)
    assert linkedin["site"] == "linkedin" and upwork["site"] == "upwork"
    assert linkedin["config"]["version"] == config.version

    assert [%{"selector_key" => "title", "count" => 14} = miss] = linkedin["misses"]

    assert Map.keys(miss) |> Enum.sort() ==
             ~w(config_version count extension_version first_seen_at last_seen_at page_kind selector_key)

    assert [%{"current" => false}] = health["devices"]

    for who <- [c.hira, c.fiza],
        do: assert(call(who, :get, "/v1/extension/health").status == 404)
  end

  test "GET /extension/configs?site: newest first, the system admin's", c do
    older = config_fixture(:upwork)
    newer = config_fixture(:upwork)

    conn = call(c.dawud, :get, "/v1/extension/configs", %{"site" => "upwork"})
    assert conn.status == 200
    assert [first, second | _] = body(conn)
    assert {first["version"], second["version"]} == {newer.version, older.version}
    assert Map.keys(first) |> Enum.sort() == ~w(published_at sha256 site version)
    assert first["sha256"] == newer.sha256

    assert call(c.dawud, :get, "/v1/extension/configs", %{"site" => "indeed"}).status == 422
    assert call(c.hira, :get, "/v1/extension/configs", %{"site" => "upwork"}).status == 404
  end
end
