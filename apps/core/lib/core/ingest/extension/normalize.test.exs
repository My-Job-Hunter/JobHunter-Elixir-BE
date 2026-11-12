defmodule Core.Ingest.Extension.NormalizeTest do
  @moduledoc "AQ-05 §11.4's normalising vectors, each a test, and §10.1's table."

  use ExUnit.Case, async: true

  alias Core.Ingest.Extension.Normalize

  doctest Normalize
  doctest Core.Ingest.Extension.Money
  doctest Core.Ingest.Extension.Facts
  doctest Core.Ingest.Extension.Read

  @now ~U[2026-11-11 09:00:00.000000Z]
  @linkedin %{site: :linkedin, now: @now, zone: "Etc/UTC", skills: []}
  @upwork %{site: :upwork, now: @now, zone: "Etc/UTC", skills: []}

  defp job(fields, opts \\ @linkedin), do: Normalize.run(fields, opts).job

  describe "engagement" do
    for {text, value} <- [
          {"Full-time", "full_time"},
          {"Part-time", "part_time"},
          {"Contract", "contract"},
          {"Temporary", "temporary"},
          {"Internship", "internship"},
          {"Volunteer", "other"}
        ] do
      test "#{text} → #{value}" do
        assert job(%{"employment_text" => unquote(text)})["engagement"] == unquote(value)
      end
    end

    test "a text nobody can read is no engagement" do
      refute Map.has_key?(job(%{"employment_text" => "Whenever"}), "engagement")
    end
  end

  describe "workplace" do
    test "Remote · Hybrid · On-site" do
      assert job(%{"workplace_text" => "Remote"})["workplace"] == "remote"
      assert job(%{"workplace_text" => "Hybrid"})["workplace"] == "hybrid"
      assert job(%{"workplace_text" => "On-site"})["workplace"] == "on_site"
    end

    test "location \"Remote (US)\" → country_list with US" do
      job = job(%{"workplace_text" => "Remote", "location_text" => "Remote (US)"})

      assert job["workplace"] == "remote"
      assert job["remote_scope"] == "country_list"
      assert job["allowed_countries"] == ["US"]
    end

    test "a remote job read from the location alone, a country named in full" do
      job = job(%{"location_text" => "United Kingdom (Remote)"})
      assert job["workplace"] == "remote"
      assert job["allowed_countries"] == ["GB"]
    end

    test "on site and hybrid keep the place as written" do
      job = job(%{"workplace_text" => "On-site", "location_text" => "Madrid, Spain"})
      assert job["onsite_locations"] == ["Madrid, Spain"]

      job = job(%{"workplace_text" => "Hybrid", "location_text" => "Lahore, Punjab, Pakistan"})
      assert job["workplace"] == "hybrid"
      assert job["onsite_locations"] == ["Lahore, Punjab, Pakistan"]
    end

    test "a region and worldwide" do
      assert job(%{"location_text" => "Remote (EMEA)"})["allowed_regions"] == ["emea"]
      assert job(%{"location_text" => "Worldwide"}, @upwork)["remote_scope"] == "global"
    end
  end

  describe "seniority" do
    for {text, value} <- [
          {"Entry level", "entry"},
          {"Associate", "associate"},
          {"Mid-Senior level", "mid_senior"},
          {"Director", "director"},
          {"Executive", "executive"},
          {"Internship", "internship"},
          {"Not Applicable", "not_applicable"}
        ] do
      test "#{text} → #{value}" do
        assert job(%{"seniority_text" => unquote(text)})["seniority"] == unquote(value)
      end
    end
  end

  describe "Upwork's experience, on its details" do
    for {text, value} <- [
          {"Entry level", :entry},
          {"Intermediate", :intermediate},
          {"Expert", :expert}
        ] do
      test "#{text} → #{value}" do
        norm = Normalize.run(%{"upwork" => %{"experience_text" => unquote(text)}}, @upwork)
        assert norm.details.experience_level == unquote(value)
        refute Map.has_key?(norm.job, "seniority")
      end
    end
  end

  describe "Upwork's money" do
    test "\"Hourly: $30.00 - $60.00\" → freelance_hourly, USD 3000–6000 a hour" do
      job = job(%{"upwork" => %{"rate_text" => "Hourly: $30.00 - $60.00"}}, @upwork)

      assert job["engagement"] == "freelance_hourly"
      assert job["comp_min_minor"] == 3000
      assert job["comp_max_minor"] == 6000
      assert job["comp_currency"] == "USD"
      assert job["comp_period"] == "hour"
      assert job["comp_source"] == "employer"
      assert job["comp_text"] == "Hourly: $30.00 - $60.00"
    end

    test ~s("Fixed-price" with "Est. budget: $500.00" → freelance_fixed, USD 50000 a project) do
      job =
        job(
          %{
            "employment_text" => "Fixed-price",
            "upwork" => %{"budget_text" => "Est. budget: $500.00"}
          },
          @upwork
        )

      assert job["engagement"] == "freelance_fixed"
      assert {job["comp_min_minor"], job["comp_max_minor"]} == {50_000, 50_000}
      assert job["comp_currency"] == "USD"
      assert job["comp_period"] == "project"
      assert job["comp_source"] == "employer"
    end
  end

  describe "LinkedIn salary, comp_source parsed_text" do
    test "\"$120K/yr - $150K/yr\"" do
      job = job(%{"salary_text" => "$120K/yr - $150K/yr"})

      assert {job["comp_min_minor"], job["comp_max_minor"]} == {12_000_000, 15_000_000}
      assert {job["comp_currency"], job["comp_period"]} == {"USD", "year"}
      assert job["comp_source"] == "parsed_text"
      assert job["comp_text"] == "$120K/yr - $150K/yr"
    end

    test "\"$50/hr\"" do
      job = job(%{"salary_text" => "$50/hr"})

      assert {job["comp_min_minor"], job["comp_max_minor"]} == {5000, 5000}
      assert {job["comp_currency"], job["comp_period"]} == {"USD", "hour"}
      assert job["comp_source"] == "parsed_text"
    end

    test "\"£55,000/yr - £65,000/yr\"" do
      job = job(%{"salary_text" => "£55,000/yr - £65,000/yr"})

      assert {job["comp_min_minor"], job["comp_max_minor"]} == {5_500_000, 6_500_000}
      assert {job["comp_currency"], job["comp_period"]} == {"GBP", "year"}
    end

    test "a figure with no period, or no currency, is not money" do
      refute Map.has_key?(job(%{"salary_text" => "$120K"}), "comp_min_minor")
      refute Map.has_key?(job(%{"salary_text" => "Competitive"}), "comp_min_minor")
    end
  end

  describe "posted, from the capture's day" do
    for {text, day, reposted} <- [
          {"2 weeks ago", ~D[2026-10-28], false},
          {"3 days ago", ~D[2026-11-08], false},
          {"Reposted 1 week ago", ~D[2026-11-04], true},
          {"1 hour ago", ~D[2026-11-11], false},
          {"yesterday", ~D[2026-11-10], false}
        ] do
      test "#{text}" do
        job = job(%{"posted_text" => unquote(text)})
        assert job["posted_on"] == unquote(Macro.escape(day))
        assert Map.get(job, "is_reposted", false) == unquote(reposted)
      end
    end

    test "the day is the organisation's: an hour ago, just after midnight in Karachi" do
      opts = %{@linkedin | now: ~U[2026-11-10 19:30:00Z], zone: "Asia/Karachi"}
      assert job(%{"posted_text" => "1 hour ago"}, opts)["posted_on"] == ~D[2026-11-10]

      opts = %{@linkedin | now: ~U[2026-11-10 19:30:00Z], zone: "Etc/UTC"}
      assert job(%{"posted_text" => "Posted 30 minutes ago"}, opts)["posted_on"] == ~D[2026-11-10]
    end
  end

  describe "applicants, a signal and LinkedIn's details" do
    test "\"Over 100 applicants\" (100, capped)" do
      norm = Normalize.run(%{"applicants_text" => "Over 100 applicants"}, @linkedin)

      assert norm.signal.applicant_count == 100
      assert norm.signal.is_applicant_count_capped == true
      assert norm.details.applicant_count == 100
      assert norm.details.is_applicant_count_capped == true
    end

    test "\"37 applicants\"" do
      norm = Normalize.run(%{"applicants_text" => "37 applicants"}, @linkedin)

      assert norm.signal.applicant_count == 37
      assert norm.signal.is_applicant_count_capped == false
    end

    test "nothing read is no signal" do
      assert Normalize.run(%{"title" => "Backend"}, @linkedin).signal == nil
    end
  end

  describe "Upwork's activity" do
    for {text, band} <- [
          {"Less than 5", {0, 5}},
          {"5 to 10", {5, 10}},
          {"10 to 15", {10, 15}},
          {"15 to 20", {15, 20}},
          {"20 to 50", {20, 50}},
          {"50+", {50, nil}}
        ] do
      test "proposals: #{text}" do
        signal =
          Normalize.run(%{"upwork" => %{"proposals_text" => unquote(text)}}, @upwork).signal

        assert {signal.proposals_min, signal.proposals_max} == unquote(band)
      end
    end

    test "each activity line as the whole line or the value alone" do
      line = %{
        "proposals_text" => "Proposals: 10 to 15",
        "interviewing_text" => "Interviewing: 2",
        "invites_text" => "Invites sent: 3",
        "unanswered_text" => "Unanswered invites: 1",
        "hires_text" => "Hires: 1",
        "last_viewed_text" => "Last viewed by client: 2 hours ago"
      }

      value = %{
        "proposals_text" => "10 to 15",
        "interviewing_text" => "2",
        "invites_text" => "3",
        "unanswered_text" => "1",
        "hires_text" => "1",
        "last_viewed_text" => "2 hours ago"
      }

      assert Normalize.run(%{"upwork" => line}, @upwork).signal ==
               Normalize.run(%{"upwork" => value}, @upwork).signal

      assert %{proposals_min: 10, proposals_max: 15, interviewing: 2, invites_sent: 3} =
               Normalize.run(%{"upwork" => value}, @upwork).signal
    end

    test "\"Last viewed by client: 2 hours ago\", read to the hour" do
      signal =
        Normalize.run(
          %{"upwork" => %{"last_viewed_text" => "Last viewed by client: 2 hours ago"}},
          @upwork
        ).signal

      assert signal.client_last_viewed_at == ~U[2026-11-11 07:00:00.000000Z]
      assert signal.slack_s == 3600
    end

    test ~s("Interviewing: 2"; "Invites sent: 3"; "Unanswered invites: 1") do
      signal =
        Normalize.run(
          %{
            "upwork" => %{
              "interviewing_text" => "Interviewing: 2",
              "invites_text" => "Invites sent: 3",
              "unanswered_text" => "Unanswered invites: 1",
              "hires_text" => "Hires: 0"
            }
          },
          @upwork
        ).signal

      assert {signal.interviewing, signal.invites_sent, signal.unanswered_invites, signal.hires} ==
               {2, 3, 1, 0}
    end
  end

  describe "Connects" do
    test ~s("Send a proposal for: 16 Connects" · "Required Connects to submit a proposal: 16") do
      assert Normalize.connects("Send a proposal for: 16 Connects") == 16
      assert Normalize.connects("Required Connects to submit a proposal: 16") == 16

      norm =
        Normalize.run(
          %{"upwork" => %{"connects_text" => "Send a proposal for: 16 Connects"}},
          @upwork
        )

      assert norm.details.connects_required == 16
    end
  end

  describe "the bid" do
    test ~s("$45.00/hr" · "$500.00") do
      assert Normalize.run(%{"bid_text" => "$45.00/hr"}, @upwork).bid ==
               %{bid_minor: 4500, bid_currency: "USD", bid_period: "hour"}

      assert Normalize.run(%{"bid_text" => "$500.00"}, @upwork).bid ==
               %{bid_minor: 50_000, bid_currency: "USD", bid_period: "project"}

      assert Normalize.run(%{"connects_spent_text" => "16 Connects"}, @upwork).connects_spent ==
               16
    end
  end

  describe "the rest of §10.1" do
    test "the company: a LinkedIn company link is its linkedin_url, another its website" do
      norm =
        Normalize.run(
          %{
            "company_name" => "Bamboo Invest",
            "company_url" => "https://www.linkedin.com/company/bamboo-invest/life"
          },
          @linkedin
        )

      assert norm.company == %{
               "name" => "Bamboo Invest",
               "linkedin_url" => "https://www.linkedin.com/company/bamboo-invest/life"
             }

      norm =
        Normalize.run(
          %{"company_name" => "TuxCare", "company_url" => "https://tuxcare.com"},
          @linkedin
        )

      assert norm.company == %{"name" => "TuxCare", "website_url" => "https://tuxcare.com"}
    end

    test "the apply kind: Easy Apply, the company's site, a proposal" do
      assert job(%{"apply_kind" => "in_platform_easy"})["apply_method"] == "in_platform_easy"
      assert job(%{"apply_kind" => "external_ats"})["apply_method"] == "external_ats"
      assert job(%{}, @upwork)["apply_method"] == "proposal"

      assert Normalize.run(%{"apply_kind" => "in_platform_easy"}, @linkedin).details.is_easy_apply
    end

    test "skills matched by name; the rest unmatched, as written" do
      skills = [%{id: "s-go", name: "Go"}, %{id: "s-pg", name: "PostgreSQL"}]

      norm =
        Normalize.run(
          %{"skills_text" => ["go", "PostgreSQL ", "Fiber", "Echo", "Go"]},
          %{@linkedin | skills: skills}
        )

      assert norm.skills == ["s-go", "s-pg"]
      assert norm.unmatched_skills == ["Fiber", "Echo"]
      assert norm.job["skills"] == [%{"skill_id" => "s-go"}, %{"skill_id" => "s-pg"}]
    end

    test "the description: sanitised, scripts gone, and its plain text" do
      norm =
        Normalize.run(
          %{
            "description_html" =>
              ~s|<p onclick="x()">We use <b>Go</b> &amp; Elixir.</p><script>steal()</script><ul><li>Remote</li></ul>|
          },
          @linkedin
        )

      assert norm.description_html ==
               "<p>We use <b>Go</b> &amp; Elixir.</p><ul><li>Remote</li></ul>"

      assert norm.job["description_md"] =~ "We use Go & Elixir."
      refute norm.job["description_md"] =~ "steal"
    end

    test "Upwork's client lines become its details" do
      details =
        Normalize.run(
          %{
            "upwork" => %{
              "client" => %{
                "payment_verified" => true,
                "rating_text" => "4.9 of 5",
                "reviews_text" => "12 reviews",
                "location_text" => "United States",
                "jobs_posted_text" => "15 jobs posted",
                "hire_rate_text" => "80% hire rate, 2 open jobs",
                "open_jobs_text" => "2 open jobs",
                "spent_text" => "$10K+ total spent",
                "hires_text" => "20 hires",
                "active_hires_text" => "3 active",
                "avg_rate_text" => "$35.50 /hr avg hourly rate paid",
                "member_since_text" => "Member since Mar 4, 2019"
              }
            }
          },
          @upwork
        ).details

      assert details.is_client_payment_verified == true
      assert Decimal.equal?(details.client_rating, Decimal.new("4.9"))
      assert details.client_reviews == 12
      assert details.client_country == "US"
      assert details.client_jobs_posted == 15
      assert details.client_hire_rate_pct == 80
      assert details.client_open_jobs == 2
      assert details.client_spent_band == :"10k_100k"
      assert details.client_hires == 20
      assert details.client_active_hires == 3

      assert {details.client_avg_hourly_minor, details.client_avg_hourly_currency} ==
               {3550, "USD"}

      assert details.client_member_since_on == ~D[2019-03-04]
    end

    test "the snapshot is the fields as sent, canonical, without captured_at" do
      a = %{
        "title" => "Go",
        "captured_at" => "2026-11-11T08:00:00Z",
        "upwork" => %{"b" => 1, "a" => 2}
      }

      b = %{
        "upwork" => %{"a" => 2, "b" => 1},
        "captured_at" => "2026-11-11T08:05:00Z",
        "title" => "Go"
      }

      assert Normalize.snapshot_body(a) == Normalize.snapshot_body(b)
      assert Normalize.snapshot_body(a) == ~s({"title":"Go","upwork":{"a":2,"b":1}})

      assert Normalize.run(a, @linkedin).snapshot.captured_at == ~U[2026-11-11 08:00:00Z]
      # A time in the future is the server's now.
      later = %{a | "captured_at" => "2027-01-01T00:00:00Z"}
      assert Normalize.run(later, @linkedin).snapshot.captured_at == @now
    end

    test "every member may be null: nothing read, nothing set" do
      norm = Normalize.run(%{"title" => nil, "skills_text" => nil, "upwork" => nil}, @linkedin)

      assert norm.job == %{}
      assert norm.company == nil
      assert norm.details == %{}
      assert norm.signal == nil
      assert norm.unmatched_skills == []
    end
  end
end
