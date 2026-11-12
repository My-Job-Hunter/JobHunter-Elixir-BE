defmodule Core.Jobs.CheckTest do
  @moduledoc """
  AQ-03 §6.3, the check's answers in order: invalid (not a link, not a job),
  in the pool (closed and archived as they are), in the pool under another
  link (via a merge), and new — with the similar postings once a title and a
  company are sent.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs.{Act, Check}

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    bamboo = company_fixture(cast.org, name: "Bamboo Invest")

    morning =
      job_fixture(scope_for(cast.fiza),
        url: "https://careers.bambooinvest.co.uk/jobs/111",
        title: "Backend Developer",
        company: bamboo,
        first_seen_at: ~U[2026-11-10 08:00:00.000000Z]
      )

    Map.merge(cast, %{bamboo: bamboo, morning: morning, fiza_scope: scope_for(cast.fiza)})
  end

  test "a link that is not one, or a board's page that is not a job, is invalid", c do
    assert Check.run(c.fiza_scope, in_team(%{url: "not a link"}, c.fiza_scope), @now) ==
             {:ok, %{state: "invalid", reason: "not_a_link"}}

    assert Check.run(
             c.fiza_scope,
             in_team(%{url: "https://www.linkedin.com/in/someone"}, c.fiza_scope),
             @now
           ) ==
             {:ok, %{state: "invalid", reason: "not_a_job"}}
  end

  test "the same posting with tracking tags is in the pool already", c do
    url = "https://www.careers.bambooinvest.co.uk/jobs/111/?utm_source=linkedin&utm_medium=social"

    assert {:ok,
            %{
              state: "in_pool",
              key: "careers.bambooinvest.co.uk/jobs/111",
              job: job,
              merged_from: nil
            }} =
             Check.run(c.fiza_scope, in_team(%{url: url}, c.fiza_scope), @now)

    assert job.id == c.morning.id
    assert job.company == %{id: c.bamboo.id, name: "Bamboo Invest"}
  end

  test "a closed or archived job answers in the pool, as it is", c do
    closed = job_fixture(c.fiza_scope, url: "https://acme.io/jobs/1", status: :closed)
    archived = job_fixture(c.fiza_scope, url: "https://acme.io/jobs/2", archived: true)

    assert {:ok, %{state: "in_pool", job: %{status: :closed}}} =
             Check.run(c.fiza_scope, in_team(%{url: closed.source_url}, c.fiza_scope), @now)

    assert {:ok, %{state: "in_pool", job: %{archived_at: %DateTime{}}}} =
             Check.run(c.fiza_scope, in_team(%{url: archived.source_url}, c.fiza_scope), @now)
  end

  test "a merged link resolves to its survivor, with what it was", c do
    fennec =
      job_fixture(c.fiza_scope,
        url: "https://www.linkedin.com/jobs/view/4012233871",
        title: "Senior Node.js Engineer"
      )

    careers =
      job_fixture(c.fiza_scope,
        url: "https://fennec.cloud/careers/node",
        title: "Node.js Engineer"
      )

    {:ok, _sheet} = Act.merge(scope_for(c.hira), careers.id, %{into_job_id: fennec.id}, @now)

    assert {:ok,
            %{state: "in_pool", job: job, merged_from: %{title: "Node.js Engineer", at: @now}}} =
             Check.run(
               c.fiza_scope,
               in_team(%{url: "https://fennec.cloud/careers/node/"}, c.fiza_scope),
               @now
             )

    assert job.id == fennec.id
  end

  test "a new link, then the similar posting once the title and the company are typed", c do
    evening = %{url: "https://careers.bambooinvest.co.uk/jobs/222"}

    assert {:ok,
            %{
              state: "new",
              key: "careers.bambooinvest.co.uk/jobs/222",
              source: :company_site,
              similar: []
            }} =
             Check.run(c.fiza_scope, in_team(evening, c.fiza_scope), @now)

    typed = Map.merge(evening, %{title: "Backend Developer", company_name: "  bamboo INVEST "})

    assert {:ok, %{state: "new", similar: [similar]}} =
             Check.run(c.fiza_scope, in_team(typed, c.fiza_scope), @now)

    assert similar.id == c.morning.id

    by_id = Map.merge(evening, %{title: "Senior Backend Developer", company_id: c.bamboo.id})
    assert {:ok, %{similar: [_one]}} = Check.run(c.fiza_scope, in_team(by_id, c.fiza_scope), @now)

    other_title = Map.merge(evening, %{title: "Product Designer", company_id: c.bamboo.id})

    assert {:ok, %{similar: []}} =
             Check.run(c.fiza_scope, in_team(other_title, c.fiza_scope), @now)
  end

  test "similar looks back organisation_settings.similar_window_days only", c do
    {:ok, _settings} = Data.Organisations.put_settings(c.org.id, %{similar_window_days: 1})

    typed = %{
      url: "https://careers.bambooinvest.co.uk/jobs/222",
      title: "Backend Developer",
      company_id: c.bamboo.id
    }

    assert {:ok, %{similar: [_morning]}} =
             Check.run(c.fiza_scope, in_team(typed, c.fiza_scope), @now)

    assert {:ok, %{similar: []}} =
             Check.run(c.fiza_scope, in_team(typed, c.fiza_scope), DateTime.add(@now, 2, :day))
  end

  test "the customer has no check", c do
    tanweer = customer_scope_for(c.tanweer)

    assert Check.run(tanweer, in_team(%{url: "https://acme.io/jobs/9"}, tanweer), @now) ==
             {:error, :not_found}
  end
end
