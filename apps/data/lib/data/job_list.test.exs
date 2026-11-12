defmodule Data.JobListTest do
  @moduledoc """
  The list's SQL against `Utils.Units`: the money filter's annualised top
  and the money sort's key agree with the Elixir factors for every period,
  and the database's CHECKs hold what the changesets hold.
  """

  use Data.DataCase, async: true

  alias Data.JobList
  alias Data.Jobs

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    %{org: org, team: team, scope: scope_for(member_fixture(team, :lead))}
  end

  test "for every period the SQL's annual top is Utils.Units.annualise/2's", %{
    team: team,
    scope: scope
  } do
    for {period, n} <- Enum.with_index(~w(hour day week month year)a) do
      job =
        job_fixture(scope, comp_max_minor: 1_000 + n, comp_currency: "USD", comp_period: period)

      annual = Utils.Units.annualise(job.comp_max_minor, period)

      at = fn min ->
        filters = %{money: %{min: min, currency: "USD", period: :year}}
        team.id |> JobList.all(filters) |> Enum.map(& &1.id) |> Enum.member?(job.id)
      end

      assert at.(annual), "#{period}: at the floor"
      refute at.(annual + 1), "#{period}: one above"
      assert JobList.money_key(job, %{currency: "USD", project?: false}) == annual
    end
  end

  test "the money sort's key: nil in another currency, or for a project unless sorting projects",
       %{scope: scope} do
    pounds = job_fixture(scope, comp_max_minor: 100, comp_currency: "GBP", comp_period: :year)
    budget = job_fixture(scope, comp_max_minor: 100, comp_currency: "USD", comp_period: :project)

    assert JobList.money_key(pounds, %{currency: "USD", project?: false}) == nil
    assert JobList.money_key(budget, %{currency: "USD", project?: false}) == nil
    assert JobList.money_key(budget, %{currency: "USD", project?: true}) == 100
  end

  test "the database refuses what the changeset would: a key twice, a closed job without closed_at",
       %{scope: scope} do
    job = job_fixture(scope, url: "https://acme.io/jobs/1")

    assert {:error, changeset} =
             Jobs.create(%{
               organisation_id: job.organisation_id,
               team_id: job.team_id,
               source: :company_site,
               source_url: "https://acme.io/jobs/1/",
               canonical_key: job.canonical_key,
               first_seen_at: job.first_seen_at,
               last_seen_at: job.first_seen_at,
               title: "Twice"
             })

    assert errors_on(changeset).url == ["is already in the pool"]

    assert {:error, changeset} = Jobs.close(job, %{status: :closed})
    assert errors_on(changeset).closed_at == ["is invalid"]
  end

  test "the pool is a team's: the same link in two teams is two rows; visible_to keeps one's own",
       %{org: org, team: team, scope: scope} do
    other = team_fixture(org)
    mine = job_fixture(scope, url: "https://acme.io/jobs/7")
    theirs = job_fixture(scope_for(member_fixture(other, :lead)), url: "https://acme.io/jobs/7")
    peer = job_fixture(scope_for(member_fixture(team, :member)))

    assert mine.canonical_key == theirs.canonical_key and mine.id != theirs.id
    ids = &(&1 |> Enum.map(fn job -> job.id end) |> Enum.sort())

    assert ids.(JobList.all(team.id, %{})) == Enum.sort([mine.id, peer.id])
    assert ids.(JobList.all(other.id, %{})) == [theirs.id]
    assert ids.(JobList.all(team.id, %{visible_to: {scope.user.id, false}})) == [mine.id]
    assert ids.(JobList.all(team.id, %{visible_to: {scope.user.id, true}})) == ids.([mine, peer])
  end
end
