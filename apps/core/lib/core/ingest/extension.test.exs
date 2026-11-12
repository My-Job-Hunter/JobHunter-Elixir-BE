defmodule Core.Ingest.ExtensionTest do
  @moduledoc """
  AQ-05 §10, §11 (P5.3, P5.4): *Save* and its replay; every path of §10.3;
  the identity; *Apply again…*. The lookup and its words are
  `Core.Ingest.Extension.WordsTest`, a capture `Core.Ingest.Extension.PoolTest`.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Ingest.Extension
  alias Data.JobParts
  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: LeadStore

  @now ~U[2026-11-11 09:00:00.000000Z]
  @linkedin "https://www.linkedin.com/jobs/view/4012233871/"
  @upwork "https://www.upwork.com/jobs/Go-developer_~01aa11bb22cc33dd44/"

  @fields %{
    "captured_at" => "2026-11-11T08:59:00Z",
    "page_kind" => "job",
    "title" => "Senior Go Engineer",
    "company_name" => "Bamboo Invest",
    "company_url" => "https://www.linkedin.com/company/bamboo-invest/",
    "location_text" => "Remote (US)",
    "workplace_text" => "Remote",
    "employment_text" => "Full-time",
    "seniority_text" => "Mid-Senior level",
    "salary_text" => "$120K/yr - $150K/yr",
    "posted_text" => "3 days ago",
    "applicants_text" => "37 applicants",
    "apply_kind" => "in_platform_easy",
    "skills_text" => ["Go", "Fiber"],
    "description_html" => "<p>Build <b>payments</b>.</p>"
  }

  setup do
    c = board_cast_fixture()
    go = skill_fixture(c.org, name: "Go")
    ext = fn user -> %{scope_for(user) | via: :extension} end

    Map.merge(c, %{
      go: go,
      ext: ext,
      sf: ext.(c.fiza),
      sq: ext.(c.qasim),
      sm: ext.(c.muaz)
    })
  end

  defp save(scope, team, profile, extra \\ %{}) do
    Extension.save(
      scope,
      Map.merge(
        %{
          "request_id" => Ecto.UUID.generate(),
          "team_id" => team.id,
          "profile_id" => profile.id,
          "url" => @linkedin,
          "fields" => @fields
        },
        extra
      ),
      @now
    )
  end

  defp applied(scope, team, profile, extra) do
    Extension.applied(
      scope,
      Map.merge(
        %{
          "request_id" => Ecto.UUID.generate(),
          "team_id" => team.id,
          "profile_id" => profile.id,
          "url" => @linkedin,
          "fields" => @fields,
          "confirmation" => "by_hand",
          "applied_via" => "in_platform_easy"
        },
        extra
      ),
      @now
    )
  end

  defp events(lead_id), do: LeadStore.events(lead_id)

  # ── Save ────────────────────────────────────────────────────────────────────

  describe "save" do
    test "a new posting: To do with the job in one transaction, by the extension", c do
      assert {:ok, {:created, written}} = save(c.sf, c.backend, c.golang)

      assert written.answer == :created
      assert written.lead.state == :todo
      assert written.lead.team.name == "Backend squad"
      assert written.unmatched_skills == ["Fiber"]
      assert written.link_path == "/leads/#{written.lead.id}?team=#{c.backend.id}"

      job = JobStore.get(c.org.id, written.job.id)
      assert job.origin == :extension
      assert job.title == "Senior Go Engineer"
      assert job.engagement == :full_time and job.seniority == :mid_senior
      assert job.comp_min_minor == 12_000_000 and job.comp_currency == "USD"
      assert job.allowed_countries == ["US"]
      assert job.company.name == "Bamboo Invest"
      assert job.company.linkedin_url == "https://www.linkedin.com/company/bamboo-invest/"
      assert job.description_html == "<p>Build <b>payments</b>.</p>"
      assert Enum.map(job.job_skills, & &1.skill_id) == [c.go.id]
      assert %{applicant_count: 37, is_easy_apply: true} = JobParts.get_details(job)
      assert %{applicant_count: 37} = JobParts.latest_signal(job.id)

      assert [%{content_type: :fields, origin: :extension, captured_by_user_id: by}] =
               Repo.all(from(s in Data.Jobs.Snapshot, where: s.job_id == ^job.id))

      assert by == c.fiza.id

      assert [%{kind: :saved, actor_kind: :extension, actor_user_id: actor, request_id: rid}] =
               events(written.lead.id)

      assert actor == c.fiza.id and is_binary(rid)

      # Activity moved: the lead's and the job's.
      assert LeadStore.get(c.org.id, written.lead.id).last_activity_at == @now
      assert job.last_activity_at == @now
    end

    test "the customer reads the event as the staff member's, with no word about the extension",
         c do
      {:ok, {:created, written}} = save(c.sf, c.backend, c.golang)
      {:ok, sheet} = Core.Leads.get(customer_scope_for(c.tanweer), written.lead.id, @now)

      assert [%{kind: :saved, actor: %{kind: :user}}] = sheet.events
    end

    test "the same request_id again answers the same lead, replayed", c do
      rid = Ecto.UUID.generate()
      {:ok, {:created, first}} = save(c.sf, c.backend, c.golang, %{"request_id" => rid})
      assert {:ok, {:replayed, again}} = save(c.sf, c.backend, c.golang, %{"request_id" => rid})

      assert again.answer == :replayed
      assert again.lead.id == first.lead.id
      assert [_one] = events(first.lead.id)
    end

    test "a pool job: refreshed, then saved on it", c do
      job = job_fixture(scope_for(c.fiza), team: c.backend, url: @linkedin, title: "Go Engineer")
      assert {:ok, {:created, written}} = save(c.sf, c.backend, c.golang)

      assert written.job.id == job.id
      job = JobStore.reload(job)
      assert job.title == "Go Engineer"
      assert job.workplace == :remote
    end

    test "a profile with a lead on the posting meets the guard", c do
      {:ok, _} = save(c.sf, c.backend, c.golang)

      assert {:error, {:duplicate_application, %{message: message}}} =
               save(c.sq, c.backend, c.golang)

      assert message =~ "“Golang backend” already has a lead on this job"
    end

    test "a request_id is required, as a UUID", c do
      assert save(c.sf, c.backend, c.golang, %{"request_id" => nil}) ==
               {:error, {:missing, [:request_id]}}

      assert {:error, {:invalid, %{"request_id" => _}}} =
               save(c.sf, c.backend, c.golang, %{"request_id" => "nope"})
    end

    test "Save is allowed from another customer's account", c do
      naveed_in = channel_fixture(c.naveed, handle: "https://www.linkedin.com/in/naveed-example/")
      assert naveed_in.identity_key == "linkedin:naveed-example"

      assert {:ok, {:created, _}} =
               save(c.sf, c.backend, c.golang, %{
                 "identity" => "https://www.linkedin.com/in/naveed-example/"
               })
    end
  end

  # ── Applied ─────────────────────────────────────────────────────────────────

  describe "applied (§10.3)" do
    test "I applied on a new posting: a lead at Applied, by hand, by the extension", c do
      assert {:ok, {:created, written}} = applied(c.sf, c.backend, c.golang, %{})

      lead = LeadStore.get(c.org.id, written.lead.id)
      assert lead.state == :in_progress and lead.stage.kind == :applied
      assert lead.applied_confirmation == :by_hand
      assert lead.applied_via == :in_platform_easy
      assert lead.applied_by_user_id == c.fiza.id

      assert [%{kind: :applied, actor_kind: :extension, occurred_at: at}] = events(lead.id)
      assert at == lead.applied_at
    end

    test "with from, the saved lead is applied: answer applied", c do
      {:ok, {:created, saved}} = save(c.sf, c.backend, c.golang)

      assert {:ok, {:applied, written}} =
               applied(c.sf, c.backend, c.golang, %{
                 "from" => %{"state" => "todo", "stage" => nil}
               })

      assert written.lead.id == saved.lead.id
      assert written.lead.state == :in_progress

      assert [%{kind: :applied, actor_kind: :extension, request_id: rid}, %{kind: :saved}] =
               events(saved.lead.id)

      assert is_binary(rid)
    end

    test "with from, a lead that moved is P4a's lead_moved", c do
      {:ok, {:created, _saved}} = applied(c.sf, c.backend, c.golang, %{})

      assert {:error, {:lead_moved, _lead}} =
               applied(c.sf, c.backend, c.golang, %{
                 "from" => %{"state" => "todo", "stage" => nil}
               })
    end

    test "a second application is refused with the guard's words", c do
      {:ok, _} = applied(c.sf, c.backend, c.golang, %{})

      assert {:error, {:duplicate_application, %{message: message}}} =
               applied(c.sq, c.backend, c.golang, %{})

      assert message =~ "applied by Fiza"
    end

    test "Upwork's confirmation page: the bid and Connects read off the page, the client's facts on the job",
         c do
      fields = %{
        "title" => "Go developer for a payments API",
        "employment_text" => "Hourly",
        "bid_text" => "$45.00/hr",
        "connects_spent_text" => "16 Connects",
        "upwork" => %{
          "rate_text" => "Hourly: $30.00 - $60.00",
          "client" => %{"payment_verified" => true, "location_text" => "United States"}
        }
      }

      assert {:ok, {:created, written}} =
               applied(c.sf, c.backend, c.golang, %{
                 "url" => @upwork,
                 "fields" => fields,
                 "confirmation" => "page_confirmation",
                 "applied_via" => nil
               })

      lead = LeadStore.get(c.org.id, written.lead.id)
      assert lead.applied_confirmation == :page_confirmation
      assert {lead.bid_minor, lead.bid_currency, lead.bid_period} == {4500, "USD", :hour}
      assert lead.connects_spent == 16
      assert lead.applied_via == :proposal

      job = JobStore.get(c.org.id, written.job.id)
      assert job.engagement == :freelance_hourly and job.comp_source == :employer
      assert %{is_client_payment_verified: true, client_country: "US"} = JobParts.get_details(job)
    end

    test "from another customer's LinkedIn: 409 identity_mismatch, nothing written", c do
      _naveed_in =
        channel_fixture(c.naveed, handle: "https://www.linkedin.com/in/naveed-example/")

      assert {:error, {:identity_mismatch, mismatch}} =
               applied(c.sf, c.backend, c.golang, %{
                 "identity" => "https://www.linkedin.com/in/naveed-example/"
               })

      assert mismatch.channel.customer.display_name == "Naveed"
      assert mismatch.acting.display_name == "Tanweer"
      refute Repo.exists?(Data.Leads.Lead)
    end

    test "from the profile's own channel, or an account nobody registered: allowed", c do
      tanweer_in = channel_fixture(c.tanweer, handle: "https://www.linkedin.com/in/tanweer/")
      :ok = Data.Profiles.put_channels(c.golang, [tanweer_in.id])

      assert {:ok, {:created, _}} =
               applied(c.sf, c.backend, c.golang, %{
                 "identity" => "https://www.linkedin.com/in/tanweer/"
               })

      other = profile_fixture(c.tanweer, title: "Rust")

      assert {:ok, {:created, _}} =
               applied(c.sf, c.backend, other, %{
                 "identity" => "https://www.linkedin.com/in/fiza-own/"
               })
    end

    test "the extension's own bodies: Upwork's confirmation after a save, and by hand with no bid",
         c do
      upwork = "https://www.upwork.com/jobs/~01ff00ee11dd22cc33"

      {:ok, {:created, saved}} =
        save(c.sf, c.backend, c.golang, %{"url" => upwork, "fields" => %{"title" => "Go API"}})

      # The confirmation page: the job as read earlier in the tab, the bid
      # and Connects as the page wrote them, no bid_minor.
      assert {:ok, {:applied, written}} =
               applied(c.sf, c.backend, c.golang, %{
                 "url" => upwork,
                 "fields" => %{
                   "title" => "Go API",
                   "page_kind" => "confirmation",
                   "bid_text" => "$500.00",
                   "connects_spent_text" => "16"
                 },
                 "confirmation" => "page_confirmation",
                 "applied_via" => "proposal",
                 "from" => %{"state" => "todo", "stage" => nil}
               })

      lead = LeadStore.get(c.org.id, written.lead.id)
      assert lead.id == saved.lead.id
      assert {lead.bid_minor, lead.bid_currency, lead.bid_period} == {50_000, "USD", :project}
      assert {lead.connects_spent, lead.applied_via} == {16, :proposal}

      # By hand, the sheet's default currency and period with no amount: no bid.
      other = profile_fixture(c.tanweer, title: "Rust")

      assert {:ok, {:created, by_hand}} =
               applied(c.sf, c.backend, other, %{
                 "url" => upwork,
                 "applied_via" => "proposal",
                 "bid_currency" => "USD",
                 "bid_period" => "hour"
               })

      assert %{bid_minor: nil, bid_currency: nil, bid_period: nil} =
               LeadStore.get(c.org.id, by_hand.lead.id)
    end

    test "a confirmation off the list is a field error", c do
      assert {:error, {:invalid, %{"confirmation" => _}}} =
               applied(c.sf, c.backend, c.golang, %{"confirmation" => "email"})
    end
  end

  describe "apply again" do
    test "with a reason: an is_again applied, the request kept; a retry replayed", c do
      {:ok, {:created, first}} = applied(c.sf, c.backend, c.golang, %{})
      lead = LeadStore.get(c.org.id, first.lead.id)
      from = %{"state" => "in_progress", "stage" => lead.stage.key}
      rid = Ecto.UUID.generate()

      body = %{
        "request_id" => rid,
        "from" => from,
        "reason" => "New CV",
        "applied_via" => "in_platform_easy"
      }

      assert {:ok, {:applied, written}} = Extension.apply_again(c.sf, lead.id, body, @now)
      assert written.lead.id == lead.id

      assert [%{kind: :applied, is_again: true, note: "New CV", request_id: ^rid} | _] =
               events(lead.id)

      assert {:ok, {:replayed, _}} = Extension.apply_again(c.sf, lead.id, body, @now)
    end

    test "without a reason: override_reason_required", c do
      {:ok, {:created, first}} = applied(c.sf, c.backend, c.golang, %{})
      lead = LeadStore.get(c.org.id, first.lead.id)

      body = %{
        "request_id" => Ecto.UUID.generate(),
        "from" => %{"state" => "in_progress", "stage" => lead.stage.key}
      }

      assert Extension.apply_again(c.sf, lead.id, body, @now) ==
               {:error, :override_reason_required}
    end
  end
end
