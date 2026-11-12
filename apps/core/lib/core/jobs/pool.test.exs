defmodule Core.Jobs.PoolTest do
  @moduledoc """
  `GET /jobs` (AQ-03 §7.1): each filter against a hand count — money
  annualised across periods and never across currencies, a project only
  against a project; posted within; a country or worldwide; the search;
  archived; `suggested_for` best first without the dismissed — the three
  sorts by keyset, and the 422s.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs.{Act, Pool}

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    scope = scope_for(cast.fiza)
    tux = company_fixture(cast.org, name: "TuxCare")

    j = fn title, attrs -> job_fixture(scope, Keyword.merge([title: title], attrs)) end

    jobs = %{
      monthly:
        j.("Go Engineer",
          comp_min_minor: 400_000,
          comp_max_minor: 550_000,
          comp_currency: "USD",
          comp_period: :month,
          workplace: :remote,
          remote_scope: :global,
          posted_on: ~D[2026-11-09],
          first_seen_at: ~U[2026-11-09 10:00:00.000000Z]
        ),
      hourly:
        j.("Elixir Developer",
          comp_min_minor: 4_500,
          comp_max_minor: 6_000,
          comp_currency: "USD",
          comp_period: :hour,
          workplace: :remote,
          remote_scope: :country_list,
          allowed_countries: ["PK", "IN"],
          url: "https://www.upwork.com/jobs/~01aa",
          posted_on: ~D[2026-10-01],
          first_seen_at: ~U[2026-11-08 10:00:00.000000Z]
        ),
      pounds:
        j.("Staff Engineer (remote work)",
          comp_max_minor: 9_000_000,
          comp_currency: "GBP",
          comp_period: :year,
          company: tux,
          workplace: :remote,
          remote_scope: :region,
          allowed_regions: ["europe"],
          first_seen_at: ~U[2026-11-07 10:00:00.000000Z]
        ),
      fixed:
        j.("Café ordering app",
          comp_max_minor: 150_000,
          comp_currency: "USD",
          comp_period: :project,
          engagement: :freelance_fixed,
          url: "https://www.upwork.com/jobs/~01bb",
          first_seen_at: ~U[2026-10-01 10:00:00.000000Z]
        ),
      archived: j.("Old role", archived: true, first_seen_at: ~U[2026-11-06 10:00:00.000000Z])
    }

    Map.merge(cast, %{scope: scope, jobs: jobs, tux: tux})
  end

  defp titles(scope, params) do
    {:ok, %{items: items}} = Pool.list(scope, in_team(params, scope), @now)
    Enum.map(items, & &1.title)
  end

  test "newest first by default, live only; archived=true lists only the archived", c do
    assert titles(c.scope, %{}) ==
             [
               "Go Engineer",
               "Elixir Developer",
               "Staff Engineer (remote work)",
               "Café ordering app"
             ]

    assert titles(c.scope, %{"archived" => "true"}) == ["Old role"]
  end

  test "money ≥ $4,000 a month: an hourly $45 job is in, a £-only job and a fixed budget are not",
       c do
    params = %{"money_min_minor" => "400000", "currency" => "usd", "period" => "month"}
    assert titles(c.scope, params) == ["Go Engineer", "Elixir Developer"]

    # $5,500 a month is 6.6M a year; the hourly top is 6,000 × 2080 = 12.48M.
    assert titles(c.scope, %{params | "money_min_minor" => "600000"}) == ["Elixir Developer"]
  end

  test "a project budget compares only with project budgets", c do
    assert titles(c.scope, %{
             "money_min_minor" => "100000",
             "currency" => "USD",
             "period" => "project"
           }) ==
             ["Café ordering app"]
  end

  test "the money filter needs all three; sort by money needs a currency", c do
    assert Pool.list(c.scope, in_team(%{"money_min_minor" => "1"}, c.scope), @now) ==
             {:error,
              {:invalid,
               %{
                 "currency" => ["is needed with the money filter"],
                 "period" => ["is needed with the money filter"]
               }}}

    assert Pool.list(c.scope, in_team(%{"sort" => "money"}, c.scope), @now) ==
             {:error, {:invalid, %{"currency" => ["is needed to sort by money"]}}}

    assert titles(c.scope, %{"sort" => "money", "currency" => "USD"}) ==
             [
               "Elixir Developer",
               "Go Engineer",
               "Café ordering app",
               "Staff Engineer (remote work)"
             ]
  end

  test "posted within: posted_on, else first seen", c do
    assert titles(c.scope, %{"posted_within" => "1"}) == ["Go Engineer"]

    assert titles(c.scope, %{"posted_within" => "7"}) == [
             "Go Engineer",
             "Staff Engineer (remote work)"
           ]

    assert Pool.list(c.scope, in_team(%{"posted_within" => "5"}, c.scope), @now) ==
             {:error, {:invalid, %{"posted_within" => ["is one of 1, 3, 7, 14 or 30 days"]}}}
  end

  test "a country: the job lists it, or is remote worldwide", c do
    assert titles(c.scope, %{"country" => "pk"}) == ["Go Engineer", "Elixir Developer"]
    assert titles(c.scope, %{"country" => "DE"}) == ["Go Engineer"]
  end

  test "comma lists of the vocabulary; a value off it is 422", c do
    assert titles(c.scope, %{"source" => "upwork"}) == ["Elixir Developer", "Café ordering app"]

    assert titles(c.scope, %{"remote_scope" => "region,country_list"}) == [
             "Elixir Developer",
             "Staff Engineer (remote work)"
           ]

    assert titles(c.scope, %{"engagement" => "freelance_fixed"}) == ["Café ordering app"]

    assert Pool.list(c.scope, in_team(%{"source" => "monster"}, c.scope), @now) ==
             {:error, {:invalid, %{"source" => ["has a value that is not one of the list"]}}}
  end

  test "q: title or company, accent- and case-insensitive, with a typo", c do
    assert titles(c.scope, %{"q" => "elixir"}) == ["Elixir Developer"]
    assert titles(c.scope, %{"q" => "CAFE"}) == ["Café ordering app"]
    assert titles(c.scope, %{"q" => "tuxcare"}) == ["Staff Engineer (remote work)"]
    assert titles(c.scope, %{"q" => "elixr"}) == ["Elixir Developer"]
  end

  test "skills: the job has any of them", c do
    go = skill_fixture(c.org, name: "Go")
    tagged = job_fixture(c.scope, title: "Tagged", skills: [{go, true}])
    assert titles(c.scope, %{"skills" => go.id}) == [tagged.title]
  end

  test "a page of 50 by keyset, the cursor opaque, null on the last page", c do
    for n <- 1..52,
        do:
          job_fixture(c.scope, title: "Bulk #{n}", first_seen_at: DateTime.add(@now, -n, :minute))

    assert {:ok, %{items: first, next_cursor: cursor}} =
             Pool.list(c.scope, in_team(%{}, c.scope), @now)

    assert length(first) == 50 and is_binary(cursor)

    assert {:ok, %{items: rest, next_cursor: nil}} =
             Pool.list(c.scope, in_team(%{"cursor" => cursor}, c.scope), @now)

    assert length(rest) == 6
    assert MapSet.disjoint?(MapSet.new(first, & &1.id), MapSet.new(rest, & &1.id))

    assert Pool.list(c.scope, in_team(%{"cursor" => "nonsense"}, c.scope), @now) ==
             {:error, {:invalid, %{"cursor" => ["is not a cursor of this list"]}}}
  end

  test "posted sorts nulls last, across pages", c do
    for n <- 1..50, do: job_fixture(c.scope, title: "Unposted #{n}")

    {:ok, %{items: first, next_cursor: cursor}} =
      Pool.list(c.scope, in_team(%{"sort" => "posted"}, c.scope), @now)

    assert Enum.take(Enum.map(first, & &1.title), 2) == ["Go Engineer", "Elixir Developer"]

    {:ok, %{items: rest, next_cursor: nil}} =
      Pool.list(c.scope, in_team(%{"sort" => "posted", "cursor" => cursor}, c.scope), @now)

    assert length(first) + length(rest) == 54
  end

  describe "suggested_for" do
    setup c do
      go = skill_fixture(c.org, name: "Go")

      {:ok, _facts} =
        Data.Profiles.update_facts(c.golang, %{
          engagement_types: ["full_time"],
          workplace_types: ["remote"]
        })

      :ok = Data.Profiles.put_skills(c.golang, [%{skill_id: go.id}])

      strong =
        job_fixture(c.scope,
          title: "Go, remote",
          engagement: :full_time,
          workplace: :remote,
          skills: [{go, true}]
        )

      on_site =
        job_fixture(c.scope,
          title: "Go, on site",
          engagement: :full_time,
          workplace: :on_site,
          skills: [{go, true}]
        )

      dismissed =
        job_fixture(c.scope, title: "Go, dismissed", engagement: :full_time, skills: [{go, true}])

      Map.merge(c, %{strong: strong, on_site: on_site, dismissed: dismissed})
    end

    test "only jobs at 70% and above for the profile, best first, not the dismissed", c do
      {:ok, _sheet} =
        Act.dismiss(c.scope, c.dismissed.id, %{profile_id: c.golang.id, reason: "money"}, @now)

      assert {:ok, %{items: rows, next_cursor: nil}} =
               Pool.list(c.scope, in_team(%{"suggested_for" => c.golang.id}, c.scope), @now)

      # 100, 100 (a job silent on all but its workplace). On site is a deal
      # breaker for a remote-only profile, so it scores 0 however well its
      # skills fit; the half-marks region and country-list jobs score 50.
      assert Enum.map(rows, & &1.title) == ["Go, remote", "Go Engineer"]

      assert %{
               profile: %{title: "Golang backend"},
               customer: %{display_name: "Tanweer"},
               score: 100
             } =
               hd(rows).best_suggestion

      # They leave the filter, but stay in the pool.
      assert "Go, dismissed" in titles(c.scope, %{})
      assert "Go, on site" in titles(c.scope, %{})
    end

    test "a profile the caller may not read is not found", c do
      imrans = profile_fixture(c.imran, title: "React")

      assert Pool.list(
               scope_for(c.muaz),
               in_team(%{"suggested_for" => imrans.id}, scope_for(c.muaz)),
               @now
             ) ==
               {:error, :not_found}
    end
  end
end
