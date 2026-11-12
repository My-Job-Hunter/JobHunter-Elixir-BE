defmodule ApiExt.PanelRoutesTest do
  @moduledoc """
  AQ-05 §11 through the router, on a device token: the context, the
  lookup, capture, *Save*, *I applied*, *Apply again…*, the config with its
  ETag, the health report — each status code of §11.4 and each shape of
  §11.3 by its keys.
  """

  use ApiExt.ExtCase, async: true

  @linkedin "https://www.linkedin.com/jobs/view/4012233871/"
  @upwork "https://www.upwork.com/jobs/~01aa11bb22cc33dd44"

  setup do
    c = board_cast_fixture()
    tanweer_in = channel_fixture(c.tanweer, handle: "https://www.linkedin.com/in/tanweer/")
    :ok = Data.Profiles.put_channels(c.golang, [tanweer_in.id])
    {device, tokens} = connected(c.fiza)
    Map.merge(c, %{token: tokens.access_token, device: device, tanweer_in: tanweer_in})
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "GET /context: §11.3's context", c do
    conn =
      call(c.token, :get, "/v1/context", %{
        "site" => "linkedin",
        "identity" => "https://www.linkedin.com/in/tanweer"
      })

    assert conn.status == 200
    ctx = body(conn)

    assert keys(ctx) == ~w(identity me pick profiles)
    assert keys(ctx["me"]) == ~w(is_admin person)
    assert ctx["identity"]["state"] == "channel"
    assert keys(ctx["identity"]["channel"]) == ~w(customer id kind label operated_by)

    assert ctx["identity"]["channel"]["customer"] == %{
             "id" => c.tanweer.id,
             "display_name" => "Tanweer"
           }

    assert ctx["pick"] == %{"profile_id" => c.golang.id, "team_id" => c.backend.id}

    [golang | _] = ctx["profiles"]
    assert keys(golang) == ~w(customer cvs id matched teams title)
    assert golang["teams"] == [%{"id" => c.backend.id, "name" => "Backend squad"}]

    assert call(c.token, :get, "/v1/context", %{"site" => "indeed"}).status == 422
  end

  test "GET /jobs/lookup: §11.3's lookup", c do
    conn =
      call(c.token, :get, "/v1/jobs/lookup", %{
        "url" => @linkedin,
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id
      })

    assert conn.status == 200
    l = body(conn)

    assert keys(l) == ~w(banner can check key lead lead_id source)
    assert l["banner"] == %{"tone" => "ok", "words" => "New job."}
    assert l["can"] == %{"save" => true, "apply" => true, "apply_again" => false}
    assert l["check"]["state"] == "new"
    assert l["lead"]["answer"] == "free"
    assert {l["key"], l["source"], l["lead_id"]} == {"linkedin:4012233871", "linkedin", nil}

    conn =
      call(c.token, :get, "/v1/jobs/lookup", %{"url" => @linkedin, "team_id" => c.frontend.id})

    assert conn.status == 200

    {_device, muaz} = connected(c.muaz)

    conn =
      call(muaz.access_token, :get, "/v1/jobs/lookup", %{
        "url" => @linkedin,
        "team_id" => c.frontend.id
      })

    assert conn.status == 404
  end

  test "POST /leads/save: 201 created, the same request_id 200 replayed", c do
    body = %{
      "request_id" => Ecto.UUID.generate(),
      "team_id" => c.backend.id,
      "profile_id" => c.golang.id,
      "url" => @linkedin,
      "fields" => %{"title" => "Senior Go Engineer", "skills_text" => ["Fiber"]}
    }

    conn = call(c.token, :post, "/v1/leads/save", body)
    assert conn.status == 201
    w = body(conn)
    assert keys(w) == ~w(answer job lead link_path unmatched_skills)
    assert w["answer"] == "created"
    assert w["lead"]["state"] == "todo"
    assert w["unmatched_skills"] == ["Fiber"]
    assert w["link_path"] == "/leads/#{w["lead"]["id"]}?team=#{c.backend.id}"
    assert w["job"]["title"] == "Senior Go Engineer"

    again = call(c.token, :post, "/v1/leads/save", body)
    assert again.status == 200
    assert body(again)["answer"] == "replayed"
    assert body(again)["lead"]["id"] == w["lead"]["id"]

    # The lookup now says saved.
    l =
      body(
        call(c.token, :get, "/v1/jobs/lookup", %{
          "url" => @linkedin,
          "team_id" => c.backend.id,
          "profile_id" => c.golang.id
        })
      )

    assert l["lead"]["answer"] == "saved"
    assert l["lead_id"] == w["lead"]["id"]
    assert l["banner"]["tone"] == "info"
  end

  test "POST /leads/applied: 201 created; with from 200 applied; a duplicate 409", c do
    base = %{
      "team_id" => c.backend.id,
      "profile_id" => c.golang.id,
      "url" => @linkedin,
      "fields" => %{"title" => "Senior Go Engineer"},
      "confirmation" => "by_hand",
      "applied_via" => "in_platform_easy"
    }

    saved =
      call(c.token, :post, "/v1/leads/save", Map.put(base, "request_id", Ecto.UUID.generate()))

    assert saved.status == 201

    conn =
      call(
        c.token,
        :post,
        "/v1/leads/applied",
        Map.merge(base, %{
          "request_id" => Ecto.UUID.generate(),
          "from" => %{"state" => "todo", "stage" => nil}
        })
      )

    assert conn.status == 200
    assert body(conn)["answer"] == "applied"
    assert body(conn)["lead"]["state"] == "in_progress"

    conn =
      call(c.token, :post, "/v1/leads/applied", Map.put(base, "request_id", Ecto.UUID.generate()))

    assert conn.status == 409
    assert code(conn) == "duplicate_application"
  end

  test "POST /leads/applied from another customer's LinkedIn: 409 identity_mismatch", c do
    naveed_in = channel_fixture(c.naveed, handle: "https://www.linkedin.com/in/naveed-example/")

    conn =
      call(c.token, :post, "/v1/leads/applied", %{
        "request_id" => Ecto.UUID.generate(),
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id,
        "url" => @linkedin,
        "fields" => %{"title" => "Senior Go Engineer"},
        "confirmation" => "by_hand",
        "applied_via" => "in_platform_easy",
        "identity" => "https://www.linkedin.com/in/naveed-example/"
      })

    assert conn.status == 409
    assert code(conn) == "identity_mismatch"

    assert body(conn)["error"]["message"] ==
             "You're signed in as Naveed's LinkedIn, not Tanweer's. Switch the acting profile, then press again."

    assert body(conn)["error"]["details"] == %{
             "channel" => %{
               "id" => naveed_in.id,
               "customer" => %{"id" => c.naveed.id, "display_name" => "Naveed"}
             }
           }
  end

  test "POST /leads/:id/apply-again: 200 applied", c do
    conn =
      call(c.token, :post, "/v1/leads/applied", %{
        "request_id" => Ecto.UUID.generate(),
        "team_id" => c.backend.id,
        "profile_id" => c.golang.id,
        "url" => @linkedin,
        "fields" => %{"title" => "Senior Go Engineer"},
        "confirmation" => "by_hand",
        "applied_via" => "in_platform_easy"
      })

    lead = body(conn)["lead"]

    again =
      call(c.token, :post, "/v1/leads/#{lead["id"]}/apply-again", %{
        "request_id" => Ecto.UUID.generate(),
        "from" => %{"state" => "in_progress", "stage" => lead["stage"]["key"]},
        "reason" => "A new CV",
        "applied_via" => "in_platform_easy"
      })

    assert again.status == 200
    assert body(again)["answer"] == "applied"

    no_reason =
      call(c.token, :post, "/v1/leads/#{lead["id"]}/apply-again", %{
        "request_id" => Ecto.UUID.generate(),
        "from" => %{"state" => "in_progress", "stage" => lead["stage"]["key"]}
      })

    assert no_reason.status == 422 and code(no_reason) == "override_reason_required"
  end

  test "POST /jobs/capture: 200 not_in_pool, then refreshed", c do
    params = %{
      "team_id" => c.backend.id,
      "url" => @upwork,
      "fields" => %{"upwork" => %{"proposals_text" => "10 to 15"}}
    }

    conn = call(c.token, :post, "/v1/jobs/capture", params)
    assert conn.status == 200
    assert body(conn) == %{"state" => "not_in_pool"}

    job_fixture(scope_for(c.fiza), team: c.backend, url: @upwork)
    conn = call(c.token, :post, "/v1/jobs/capture", params)
    assert conn.status == 200
    answer = body(conn)
    assert keys(answer) == ~w(filled job signals state unmatched_skills)
    assert answer["signals"]["count"] == 1
    assert answer["signals"]["latest"]["proposals_min"] == 10
  end

  test "GET /config: the live document, its ETag, then 304", c do
    config = config_fixture(:upwork)

    conn = call(c.token, :get, "/v1/config", %{"site" => "upwork"})
    assert conn.status == 200
    assert conn.resp_body == config.body
    assert get_resp_header(conn, "etag") == [~s("#{config.sha256}")]
    assert get_resp_header(conn, "x-aq-config-version") == [to_string(config.version)]
    assert hd(get_resp_header(conn, "content-type")) =~ "application/json"

    conn =
      call(c.token, :get, "/v1/config", %{"site" => "upwork"}, [
        {"if-none-match", ~s("#{config.sha256}")}
      ])

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "x-aq-config-version") == [to_string(config.version)]

    stale =
      call(c.token, :get, "/v1/config", %{"site" => "upwork"}, [{"if-none-match", ~s("0000")}])

    assert stale.status == 200

    assert call(c.token, :get, "/v1/config", %{"site" => "indeed"}).status == 422
  end

  test "POST /health: 204; off the contract 422", c do
    report = %{
      "extension_version" => "0.1.0",
      "misses" => [
        %{
          "site" => "linkedin",
          "page_kind" => "job",
          "selector_key" => "salary_text",
          "config_version" => 1,
          "count" => 2
        }
      ]
    }

    assert call(c.token, :post, "/v1/health", report).status == 204

    bad = put_in(report, ["misses", Access.at(0), "count"], 0)
    assert call(c.token, :post, "/v1/health", bad).status == 422
  end

  test "the device's last_seen_at moves on its requests", c do
    old = ~U[2026-11-01 09:00:00.000000Z]
    {1, _} = Repo.update_all(Data.Devices.Device, set: [last_seen_at: old])

    call(c.token, :get, "/v1/me")
    assert DateTime.after?(Data.Devices.get(c.org.id, c.device.id).last_seen_at, old)
  end
end
