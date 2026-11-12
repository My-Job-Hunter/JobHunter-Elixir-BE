defmodule ApiTeam.JobControllerTest do
  @moduledoc """
  The console's job pool routes (AQ-03 §7) in §7.1's exact shapes: the
  check's three states, the sheet with every column by name, the row and
  the page, the suggestion; the two 409s; §4.2's 403; the customer's 404.
  """

  use ApiTeam.TeamCase, async: true

  @money ~w(min_minor max_minor currency period source is_estimate is_undisclosed text)
  @row ~w(id title team company source engagement workplace remote_scope onsite_locations money posted_on
          first_seen_at status
          archived_at best_suggestion)
  @columns ~w(source_url canonical_key source_job_id origin last_seen_at is_reposted poster_name description_md
              description_html seniority category openings allowed_countries allowed_regions required_timezones
              min_overlap_hours overlap_from_time overlap_to_time is_relocation_offered visa
              visa_text duration hours_min hours_max start_on is_immediate_start comp_min_minor comp_max_minor
              comp_currency comp_period comp_source comp_text is_comp_undisclosed equity_min_bp equity_max_bp
              equity_kind apply_method apply_url valid_through_on closed_at close_reason last_activity_at)
  @sheet @row ++
           @columns ++
           ~w(skills platform_details snapshots merged_from suggestions created_by last_changed leads
              hidden_leads signals can)
  @company ~w(id name domain website_url linkedin_url size_band industry hq_country notes_md open_jobs
              created_by inserted_at)
  @suggestion ~w(profile customer score parts dismissed)

  setup do
    cast = board_cast_fixture()
    go = skill_fixture(cast.org, name: "Go")
    Map.put(cast, :go, go)
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "POST /jobs/check, then POST /jobs: §7.1's shapes, and the check again says in_pool", c do
    url = "https://careers.bambooinvest.co.uk/jobs/111"

    assert body(call(c.fiza, :post, "/v1/jobs/check", %{team_id: c.backend.id, url: "nope"})) ==
             %{"state" => "invalid", "reason" => "not_a_link"}

    assert %{
             "state" => "new",
             "key" => "careers.bambooinvest.co.uk/jobs/111",
             "source" => "company_site",
             "similar" => []
           } =
             body(call(c.fiza, :post, "/v1/jobs/check", %{team_id: c.backend.id, url: url}))

    conn =
      call(c.fiza, :post, "/v1/jobs", %{
        team_id: c.backend.id,
        url: url,
        title: "Backend Developer",
        company: %{name: "Bamboo Invest"},
        workplace: "on_site",
        engagement: "full_time",
        comp_min_minor: 5_500_000,
        comp_max_minor: 6_500_000,
        comp_currency: "GBP",
        comp_period: "year",
        comp_source: "platform_estimate",
        skills: [%{skill_id: c.go.id, is_required: true}],
        snapshot_text: "Backend Developer at Bamboo Invest"
      })

    assert conn.status == 201
    sheet = body(conn)
    assert keys(sheet) == Enum.sort(@sheet)
    assert keys(sheet["money"]) == Enum.sort(@money)
    assert keys(sheet["company"]) == Enum.sort(@company)
    assert keys(sheet["can"]) == ~w(archive close edit merge reopen share unarchive)
    # AQ-05 §11.2: the signals line, none yet.
    assert sheet["signals"] == %{"latest" => nil, "count" => 0}
    assert sheet["team"] == %{"id" => c.backend.id, "name" => "Backend squad"}

    assert %{
             "money" => %{
               "currency" => "GBP",
               "period" => "year",
               "is_estimate" => true,
               "source" => "platform_estimate"
             },
             "company" => %{
               "name" => "Bamboo Invest",
               "open_jobs" => [%{"title" => "Backend Developer"}]
             },
             "skills" => [%{"name" => "Go", "is_required" => true, "id" => _}],
             "snapshots" => [
               %{"origin" => "manual", "content_type" => "text", "by" => %{"name" => "Fiza"}}
             ],
             "created_by" => %{"name" => "Fiza", "user_id" => _, "photo_url" => nil},
             "last_changed" => %{"by" => %{"name" => "Fiza"}},
             "platform_details" => nil,
             "merged_from" => [],
             "best_suggestion" => nil
           } = sheet

    check =
      body(
        call(c.fiza, :post, "/v1/jobs/check", %{
          team_id: c.backend.id,
          url: url <> "/?utm_source=x"
        })
      )

    assert %{"state" => "in_pool", "merged_from" => nil, "hidden" => false, "job" => job} = check
    assert keys(job) == Enum.sort(@row)
    assert job["id"] == sheet["id"]

    assert body(call(c.qasim, :get, "/v1/jobs/#{sheet["id"]}"))["id"] == sheet["id"]
  end

  test "a link already in the pool is 409 job_exists with the job's id and title", c do
    job =
      job_fixture(scope_for(c.qasim), url: "https://acme.io/jobs/1", title: "Backend Developer")

    conn =
      call(c.fiza, :post, "/v1/jobs", %{
        team_id: c.backend.id,
        url: "https://www.acme.io/jobs/1/",
        title: "Again"
      })

    assert conn.status == 409

    assert body(conn)["error"] == %{
             "code" => "job_exists",
             "message" => "That link is already in the pool: Backend Developer.",
             "details" => %{"job_id" => job.id, "title" => "Backend Developer"}
           }
  end

  test "GET /jobs: a page of rows; PATCH; close with a stale from is 409 job_moved", c do
    job = job_fixture(scope_for(c.fiza), title: "Go Engineer")

    page = body(call(c.muaz, :get, "/v1/jobs", %{team_id: c.backend.id, q: "go"}))
    assert keys(page) == ["items", "next_cursor"]
    assert [%{"title" => "Go Engineer"} = row] = page["items"]
    assert keys(row) == Enum.sort(@row)

    assert call(c.muaz, :get, "/v1/jobs", %{team_id: c.backend.id, sort: "money"}).status == 422

    assert %{"workplace" => "remote"} =
             body(call(c.muaz, :patch, "/v1/jobs/#{job.id}", %{workplace: "remote"}))

    assert %{"status" => "closed", "close_reason" => "filled"} =
             body(
               call(c.qasim, :post, "/v1/jobs/#{job.id}/close", %{from: "open", reason: "filled"})
             )

    conn = call(c.fiza, :post, "/v1/jobs/#{job.id}/close", %{from: "open", reason: "expired"})
    assert conn.status == 409

    assert body(conn)["error"] == %{
             "code" => "job_moved",
             "message" => "This job changed while you were looking. It's now closed.",
             "details" => %{"status" => "closed"}
           }

    assert %{"status" => "open"} =
             body(call(c.fiza, :post, "/v1/jobs/#{job.id}/reopen", %{from: "closed"}))
  end

  test "merge and archive: 403 with §4.2's words for a member, the survivor's sheet for a lead",
       c do
    survivor =
      job_fixture(scope_for(c.fiza), url: "https://www.linkedin.com/jobs/view/4012233871")

    merged =
      job_fixture(scope_for(c.fiza),
        url: "https://fennec.cloud/careers/1",
        description_md: "Build it."
      )

    conn = call(c.muaz, :post, "/v1/jobs/#{merged.id}/merge", %{into_job_id: survivor.id})
    assert conn.status == 403
    assert body(conn)["error"]["message"] == "Only a lead can merge or archive a job."
    assert call(c.muaz, :post, "/v1/jobs/#{survivor.id}/archive").status == 403

    sheet = body(call(c.hira, :post, "/v1/jobs/#{merged.id}/merge", %{into_job_id: survivor.id}))
    assert %{"id" => id, "description_md" => "Build it.", "merged_from" => [merged_from]} = sheet
    assert id == survivor.id
    assert keys(merged_from) == ~w(at by source_url title)
    assert call(c.hira, :get, "/v1/jobs/#{merged.id}").status == 404

    assert %{"state" => "in_pool", "merged_from" => %{"title" => _, "at" => _}} =
             body(
               call(c.fiza, :post, "/v1/jobs/check", %{
                 team_id: c.backend.id,
                 url: "https://fennec.cloud/careers/1"
               })
             )

    assert %{"archived_at" => at} = body(call(c.bilal, :post, "/v1/jobs/#{survivor.id}/archive"))
    assert is_binary(at)

    assert body(call(c.bilal, :get, "/v1/jobs", %{team_id: c.backend.id, archived: "true"}))[
             "items"
           ]
           |> length() == 1

    assert %{"archived_at" => nil} =
             body(call(c.bilal, :post, "/v1/jobs/#{survivor.id}/unarchive"))
  end

  test "suggestions and dismissals in their shape", c do
    job = job_fixture(scope_for(c.fiza), engagement: :full_time)

    assert [suggestion] = body(call(c.fiza, :get, "/v1/jobs/#{job.id}/suggestions"))
    assert keys(suggestion) == Enum.sort(@suggestion)

    assert %{
             "profile" => %{"title" => "Golang backend"},
             "customer" => %{"display_name" => "Tanweer"}
           } = suggestion

    sheet =
      body(
        call(c.fiza, :post, "/v1/jobs/#{job.id}/dismissals", %{
          profile_id: c.golang.id,
          reason: "money"
        })
      )

    assert [%{"dismissed" => %{"reason" => "money", "by" => %{"name" => "Fiza"}} = dismissed}] =
             sheet["suggestions"]

    assert keys(dismissed) == ~w(at by note reason)

    assert %{"suggestions" => []} =
             body(call(c.fiza, :delete, "/v1/jobs/#{job.id}/dismissals/#{c.golang.id}"))
  end

  test "platform details: the source's row; 422 for a source without a table", c do
    job = job_fixture(scope_for(c.fiza), url: "https://www.workatastartup.com/jobs/65432")

    assert %{
             "platform_details" => %{
               "batch" => "W24",
               "team_size" => 12,
               "stage_text" => nil,
               "experience_text" => nil
             }
           } =
             body(
               call(c.fiza, :put, "/v1/jobs/#{job.id}/platform-details", %{
                 batch: "w24",
                 team_size: 12
               })
             )

    upwork = job_fixture(scope_for(c.fiza), url: "https://www.upwork.com/jobs/~01ab")

    assert %{"platform_details" => %{"client_rating" => 4.9, "experience_level" => "entry"}} =
             body(
               call(c.fiza, :put, "/v1/jobs/#{upwork.id}/platform-details", %{
                 client_rating: "4.90",
                 experience_level: "entry"
               })
             )

    site = job_fixture(scope_for(c.fiza))

    assert call(c.fiza, :put, "/v1/jobs/#{site.id}/platform-details", %{batch: "W24"}).status ==
             422
  end

  test "the customer gets 404 on the console's job routes", c do
    tanweer = Data.Accounts.get_user(c.tanweer.user_id)
    job = job_fixture(scope_for(c.fiza))

    assert call(tanweer, :get, "/v1/jobs").status == 404
    assert call(tanweer, :get, "/v1/jobs/#{job.id}").status == 404

    assert call(tanweer, :post, "/v1/jobs/check", %{
             team_id: c.backend.id,
             url: "https://acme.io/x"
           }).status == 404

    assert call(tanweer, :get, "/v1/companies").status == 404
  end
end
