defmodule Core.Jobs.SuggestTest do
  @moduledoc """
  AQ-03 §9, the score's parts: each part's marks, unknown parts left out and
  the rest re-weighed to 100, and — over the cast — a Go job against
  Tanweer's *Golang backend* profile.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs.Suggest

  doctest Core.Jobs.Regions

  @now ~U[2026-11-10 09:00:00.000000Z]

  defp skill(id, name, required? \\ true),
    do: %{skill_id: id, is_required: required?, skill: %{name: name}}

  defp profile(attrs) do
    Map.merge(
      %{
        profile_skills: [],
        engagement_types: [],
        workplace_types: [],
        min_comp_minor: nil,
        min_comp_currency: nil,
        min_comp_period: nil,
        work_timezones: [],
        work_countries: [],
        seniority: nil
      },
      Map.new(attrs)
    )
  end

  defp job(attrs) do
    Map.merge(
      %{
        job_skills: [],
        engagement: nil,
        workplace: nil,
        remote_scope: nil,
        allowed_countries: [],
        allowed_regions: [],
        comp_min_minor: nil,
        comp_max_minor: nil,
        comp_currency: nil,
        comp_period: nil,
        is_comp_undisclosed: false,
        required_timezones: [],
        overlap_from_time: nil,
        overlap_to_time: nil,
        min_overlap_hours: nil,
        seniority: nil
      },
      Map.new(attrs)
    )
  end

  defp part(result, name), do: Enum.find(result.parts, &(&1.part == name))

  test "a job and a profile silent on everything score nothing, with no parts" do
    assert Suggest.score(profile([]), job([]), @now) == %{score: 0, parts: []}
  end

  test "a part either side is silent on is left out, and the rest re-weighed to 100" do
    result =
      Suggest.score(
        profile(engagement_types: ["full_time"], seniority: :mid_senior),
        job(engagement: :full_time, seniority: :associate, workplace: :remote),
        @now
      )

    assert Enum.map(result.parts, & &1.part) == ["engagement", "seniority"]
    assert Enum.map(result.parts, & &1.weight) == [75, 25]
    assert Enum.sum(Enum.map(result.parts, & &1.weight)) == 100
    # 15 × 1 + 5 × 0.5 over 20.
    assert result.score == 88
  end

  test "skills: required in proportion, nice-to-have counting half, said in words" do
    p = profile(profile_skills: [%{skill_id: "go"}, %{skill_id: "pg"}])

    j =
      job(
        job_skills: [skill("go", "Go"), skill("pg", "PostgreSQL"), skill("kafka", "Kafka", false)]
      )

    assert %{got: got, why: "Has Go and PostgreSQL, not Kafka", weight: 100} =
             part(Suggest.score(p, j, @now), "skills")

    # 2 of 2 required, 0 of 1 nice: 2 / 2.5.
    assert got == 0.8
  end

  test "workplace: a country list needs a profile country; a region is half at best" do
    p = profile(workplace_types: ["remote"], work_countries: ["PK"])

    listed = &job(workplace: :remote, remote_scope: :country_list, allowed_countries: &1)
    assert part(Suggest.score(p, listed.(["PK", "IN"]), @now), "workplace").got == 1.0
    assert part(Suggest.score(p, listed.(["US"]), @now), "workplace").got == 0.0

    region = &job(workplace: :remote, remote_scope: :region, allowed_regions: &1)
    assert part(Suggest.score(p, region.(["south_asia"]), @now), "workplace").got == 0.5
    assert part(Suggest.score(p, region.(["eu"]), @now), "workplace").got == 0.0

    assert part(Suggest.score(p, job(workplace: :on_site), @now), "workplace").got == 0.0
    refute part(Suggest.score(p, job(workplace: :unknown), @now), "workplace")
  end

  test "a deal breaker: a workplace or engagement the profile doesn't take scores 0, said why" do
    p =
      profile(
        engagement_types: ["full_time"],
        workplace_types: ["remote"],
        work_countries: ["PK"],
        seniority: :mid_senior
      )

    fits = [engagement: :full_time, seniority: :mid_senior]

    assert Suggest.score(p, job(fits ++ [workplace: :remote]), @now).score == 100

    on_site = Suggest.score(p, job(fits ++ [workplace: :on_site]), @now)
    assert on_site.score == 0

    assert part(on_site, "workplace").why ==
             "Deal breaker: This profile doesn't take on site work"

    # The rest is still listed, in its own words.
    assert part(on_site, "seniority").why == "Mid senior, as the profile is"

    hybrid = Suggest.score(p, job(fits ++ [workplace: :hybrid]), @now)
    assert hybrid.score == 0

    contract = Suggest.score(p, job(engagement: :contract, workplace: :remote), @now)
    assert contract.score == 0
    assert part(contract, "engagement").why == "Deal breaker: This profile doesn't take contract"

    # Remote, but only from countries the profile isn't in.
    us_only =
      job(fits ++ [workplace: :remote, remote_scope: :country_list, allowed_countries: ["US"]])

    assert Suggest.score(p, us_only, @now).score == 0

    # A region the profile may be in is half marks, not a deal breaker.
    asia =
      job(fits ++ [workplace: :remote, remote_scope: :region, allowed_regions: ["south_asia"]])

    assert Suggest.score(p, asia, @now).score > 0

    # Silence is never a deal breaker.
    assert Suggest.score(p, job(fits ++ [workplace: :unknown]), @now).score == 100
  end

  test "money: same currency, comparable periods; undisclosed is half; another currency is silence" do
    p = profile(min_comp_minor: 400_000, min_comp_currency: "USD", min_comp_period: :month)

    hourly = job(comp_min_minor: 4_500, comp_currency: "USD", comp_period: :hour)
    assert part(Suggest.score(p, hourly, @now), "money").got == 1.0

    low = job(comp_max_minor: 2_000_000, comp_currency: "USD", comp_period: :year)
    assert part(Suggest.score(p, low, @now), "money").got == 0.0

    assert part(Suggest.score(p, job(is_comp_undisclosed: true), @now), "money").got == 0.5

    refute part(
             Suggest.score(
               p,
               job(comp_max_minor: 9_000_000, comp_currency: "GBP", comp_period: :year),
               @now
             ),
             "money"
           )

    refute part(
             Suggest.score(
               p,
               job(comp_max_minor: 150_000, comp_currency: "USD", comp_period: :project),
               @now
             ),
             "money"
           )
  end

  test "time zone: a shared zone, within 3 hours, or the profile's day across the window" do
    p = profile(work_timezones: ["Asia/Karachi"])

    assert part(Suggest.score(p, job(required_timezones: ["Asia/Karachi"]), @now), "timezone").got ==
             1.0

    assert part(Suggest.score(p, job(required_timezones: ["Asia/Dubai"]), @now), "timezone").got ==
             0.5

    assert part(Suggest.score(p, job(required_timezones: ["America/New_York"]), @now), "timezone").got ==
             0.0

    # 09:00–17:00 in Karachi is 04:00–12:00 UTC.
    window = &job(overlap_from_time: &1, overlap_to_time: &2, min_overlap_hours: 4)

    assert part(Suggest.score(p, window.(~T[08:00:00], ~T[16:00:00]), @now), "timezone").got ==
             1.0

    assert part(Suggest.score(p, window.(~T[10:00:00], ~T[18:00:00]), @now), "timezone").got ==
             0.5

    assert part(Suggest.score(p, window.(~T[16:00:00], ~T[23:00:00]), @now), "timezone").got ==
             0.0
  end

  test "seniority: equal is full, adjacent half, further nothing; not applicable is silence" do
    p = profile(seniority: :mid_senior)
    assert part(Suggest.score(p, job(seniority: :mid_senior), @now), "seniority").got == 1.0
    assert part(Suggest.score(p, job(seniority: :director), @now), "seniority").got == 0.5
    assert part(Suggest.score(p, job(seniority: :entry), @now), "seniority").got == 0.0
    refute part(Suggest.score(p, job(seniority: :not_applicable), @now), "seniority")
  end

  describe "over the cast" do
    setup do
      cast = board_cast_fixture()
      go = skill_fixture(cast.org, name: "Go")
      pg = skill_fixture(cast.org, name: "PostgreSQL")
      kafka = skill_fixture(cast.org, name: "Kafka")

      {:ok, _facts} =
        Data.Profiles.update_facts(cast.golang, %{
          engagement_types: ["full_time", "contract"],
          workplace_types: ["remote"],
          min_comp_minor: 400_000,
          min_comp_currency: "USD",
          min_comp_period: "month",
          work_timezones: ["Asia/Karachi"],
          work_countries: ["PK"],
          seniority: "mid_senior"
        })

      :ok = Data.Profiles.put_skills(cast.golang, [%{skill_id: go.id}, %{skill_id: pg.id}])
      Map.merge(cast, %{go: go, pg: pg, kafka: kafka, golang: Data.Profiles.reload(cast.golang)})
    end

    test "a Go job scores Tanweer's Golang backend profile from its parts", c do
      job =
        job_fixture(scope_for(c.fiza),
          title: "Senior Go Engineer",
          engagement: :full_time,
          workplace: :remote,
          remote_scope: :global,
          comp_min_minor: 500_000,
          comp_max_minor: 650_000,
          comp_currency: "USD",
          comp_period: :month,
          skills: [{c.go, true}, {c.pg, true}, {c.kafka, false}]
        )

      result = Suggest.score(c.golang, job, @now)

      # Time zone and seniority: the job is silent, so they are left out.
      assert Enum.map(result.parts, & &1.part) == ~w(skills engagement workplace money)
      assert Enum.map(result.parts, & &1.weight) == [47, 18, 18, 17]
      assert part(result, "skills").why == "Has Go and PostgreSQL, not Kafka"
      # (40 × 0.8 + 15 + 15 + 15) / 85
      assert result.score == 91
      assert result.score >= Suggest.threshold()
    end

    test "the same job on-site in London is not suggested, however well the rest fits", c do
      job =
        job_fixture(scope_for(c.fiza),
          title: "Backend Developer",
          engagement: :full_time,
          workplace: :on_site,
          comp_min_minor: 500_000,
          comp_currency: "USD",
          comp_period: :month,
          skills: [{c.go, true}, {c.pg, true}]
        )

      result = Suggest.score(c.golang, job, @now)
      assert result.score == 0
      assert result.score < Suggest.threshold()
      assert part(result, "skills").got == 1.0
      assert part(result, "workplace").why =~ "Deal breaker"
    end
  end
end
