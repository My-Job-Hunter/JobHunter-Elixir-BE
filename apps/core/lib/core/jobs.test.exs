defmodule Core.JobsTest do
  @moduledoc """
  A job added, read and edited (AQ-03 §7): the link becomes the key, the
  company is found by its normalised name or made, the check runs again in
  the transaction (409 `job_exists`), every write leaves its audit row, and
  the platform details belong to the source's table.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs
  alias Core.Jobs.{Act, Check}
  alias Data.Audit
  alias Data.Jobs.Job

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    go = skill_fixture(cast.org, name: "Go")
    pg = skill_fixture(cast.org, name: "PostgreSQL")
    Map.merge(cast, %{go: go, pg: pg, fiza_scope: scope_for(cast.fiza)})
  end

  defp audit(job_id, org_id), do: Audit.list_for_subject(org_id, "jobs", job_id)

  test "POST /jobs: the key from the link, a new company by name, skills, a snapshot, the audit row",
       c do
    params = %{
      "url" => "https://www.careers.bambooinvest.co.uk/jobs/111/?utm_source=linkedin",
      "title" => "  Backend Developer ",
      "company" => %{"name" => "Bamboo Invest", "website_url" => "https://bambooinvest.co.uk"},
      "workplace" => "on_site",
      "engagement" => "full_time",
      "allowed_countries" => ["gb"],
      "comp_min_minor" => 5_500_000,
      "comp_max_minor" => 6_500_000,
      "comp_currency" => "gbp",
      "comp_period" => "year",
      "skills" => [
        %{"skill_id" => c.go.id, "is_required" => true},
        %{"skill_id" => c.pg.id, "is_required" => false}
      ],
      "snapshot_text" => "We are hiring a backend developer.",
      "canonical_key" => "ignored",
      "status" => "closed"
    }

    assert {:ok, sheet} = Jobs.create(c.fiza_scope, in_team(params, c.fiza_scope), @now)

    assert %{
             title: "Backend Developer",
             canonical_key: "careers.bambooinvest.co.uk/jobs/111",
             source: :company_site,
             origin: :manual,
             status: :open,
             first_seen_at: @now,
             allowed_countries: ["GB"],
             money: %{
               min_minor: 5_500_000,
               max_minor: 6_500_000,
               currency: "GBP",
               period: :year,
               is_estimate: false
             },
             company: %{name: "Bamboo Invest", website_url: "https://bambooinvest.co.uk"},
             created_by: %{name: "Fiza"},
             last_changed: %{by: %{name: "Fiza"}, at: @now},
             platform_details: nil,
             can: %{edit: true, close: true, reopen: false, merge: false, archive: false}
           } = sheet

    assert [%{name: "Go", is_required: true}, %{name: "PostgreSQL", is_required: false}] =
             sheet.skills

    assert [%{origin: :manual, content_type: :text, by: %{name: "Fiza"}}] = sheet.snapshots
    assert [%{action: "created", actor_user_id: actor}] = audit(sheet.id, c.org.id)
    assert actor == c.fiza.id

    # The company is found again by its normalised name, not made twice.
    assert {:ok, again} =
             Jobs.create(
               c.fiza_scope,
               in_team(
                 %{
                   url: "https://careers.bambooinvest.co.uk/jobs/222",
                   title: "QA",
                   company: %{name: " bamboo  invest"}
                 },
                 c.fiza_scope
               ),
               @now
             )

    assert again.company.id == sheet.company.id
    assert length(again.company.open_jobs) == 2
  end

  test "a link already in the pool is 409 job_exists, never a second row — the race the check missed",
       c do
    url = "https://www.linkedin.com/jobs/view/4012233871"

    # The form checked and saw "new"; somebody else added it meanwhile.
    assert {:ok, %{state: "new"}} =
             Check.run(c.fiza_scope, in_team(%{url: url}, c.fiza_scope), @now)

    first = job_fixture(scope_for(c.qasim), url: url, title: "Senior Node.js Engineer")

    tracked = "https://www.linkedin.com/jobs/search/?currentJobId=4012233871&keywords=node"

    assert {:error, {:job_exists, existing}} =
             Jobs.create(
               c.fiza_scope,
               in_team(%{url: tracked, title: "Node engineer"}, c.fiza_scope),
               @now
             )

    assert existing.id == first.id
    assert Repo.aggregate(Job, :count) == 1
  end

  test "a merged link is job_exists too, naming the survivor", c do
    survivor = job_fixture(c.fiza_scope, url: "https://acme.io/jobs/1")
    merged = job_fixture(c.fiza_scope, url: "https://acme.io/jobs/2")

    {:ok, _sheet} =
      Act.merge(scope_for(c.hira), merged.id, %{into_job_id: survivor.id}, @now)

    assert {:error, {:job_exists, %{id: id}}} =
             Jobs.create(
               c.fiza_scope,
               in_team(%{url: "https://acme.io/jobs/2/", title: "Again"}, c.fiza_scope),
               @now
             )

    assert id == survivor.id
  end

  test "the link and the title are required; a board page is not a job", c do
    assert Jobs.create(c.fiza_scope, in_team(%{title: "No link"}, c.fiza_scope), @now) ==
             {:error, {:missing, [:url]}}

    assert Jobs.create(
             c.fiza_scope,
             in_team(%{url: "https://www.linkedin.com/in/someone", title: "X"}, c.fiza_scope),
             @now
           ) ==
             {:error, {:invalid, %{"url" => ["is not a job posting"]}}}

    assert {:error, %Ecto.Changeset{} = changeset} =
             Jobs.create(
               c.fiza_scope,
               in_team(%{url: "https://acme.io/jobs/1"}, c.fiza_scope),
               @now
             )

    assert errors_on(changeset).title == ["can't be blank"]
  end

  test "an amount without its currency is a field error; a skill off the vocabulary too", c do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Jobs.create(
               c.fiza_scope,
               in_team(
                 %{url: "https://acme.io/j/1", title: "X", comp_min_minor: 100},
                 c.fiza_scope
               ),
               @now
             )

    assert errors_on(changeset).comp_currency == ["is needed with an amount"]

    other = skill_fixture(organisation_fixture())

    assert Jobs.create(
             c.fiza_scope,
             in_team(
               %{url: "https://acme.io/j/1", title: "X", skills: [%{skill_id: other.id}]},
               c.fiza_scope
             ),
             @now
           ) ==
             {:error, {:invalid, %{"skills" => ["has a skill that is not in the vocabulary"]}}}
  end

  test "PATCH: any field but the link; the audit row holds what changed, before and after", c do
    job = job_fixture(c.fiza_scope, title: "Backend Developer", skills: [{c.go, true}])

    assert {:ok, sheet} =
             Jobs.update(
               scope_for(c.qasim),
               job.id,
               %{
                 "title" => "Backend Engineer",
                 "source_url" => "https://elsewhere.io/x",
                 "workplace" => "remote",
                 "skills" => [
                   %{"skill_id" => c.go.id, "is_required" => true},
                   %{"skill_id" => c.pg.id}
                 ]
               },
               @now
             )

    assert %{title: "Backend Engineer", workplace: :remote, last_changed: %{by: %{name: "Qasim"}}} =
             sheet

    assert sheet.source_url == job.source_url
    assert length(sheet.skills) == 2

    # The fixture writes through `Data.Jobs`, so the edit is the job's first audit row.
    assert [%{action: "updated", before: before, after: after_}] = audit(job.id, c.org.id)
    assert Map.keys(before) |> Enum.sort() == ["skills", "title", "workplace"]
    assert before["title"] == "Backend Developer" and after_["title"] == "Backend Engineer"
    assert before["workplace"] == nil and after_["workplace"] == "remote"
  end

  test "platform details: the source's table, 422 for a source without one", c do
    upwork =
      job_fixture(c.fiza_scope, url: "https://www.upwork.com/jobs/~01abc", title: "Go developer")

    assert {:ok, sheet} =
             Jobs.put_platform_details(
               c.fiza_scope,
               upwork.id,
               %{
                 "experience_level" => "expert",
                 "connects_required" => 16,
                 "client_country" => "us",
                 "client_spent_band" => "10k_100k"
               },
               @now
             )

    assert %{experience_level: :expert, connects_required: 16, client_country: "US"} =
             sheet.platform_details

    # Upwork's level becomes the job's seniority when it had none.
    assert sheet.seniority == :mid_senior

    site = job_fixture(c.fiza_scope)

    assert Jobs.put_platform_details(c.fiza_scope, site.id, %{"batch" => "W24"}, @now) ==
             {:error, {:invalid, %{"platform_details" => ["a company_site job has none"]}}}
  end

  test "a job of another organisation, or for the customer, is not found", c do
    other = organisation_fixture()
    stranger = admin_fixture(other)
    theirs = job_fixture(scope_for(stranger), team: team_fixture(other))

    assert Jobs.get(c.fiza_scope, theirs.id, @now) == {:error, :not_found}

    mine = job_fixture(c.fiza_scope)
    assert Jobs.get(customer_scope_for(c.tanweer), mine.id, @now) == {:error, :not_found}
    assert Jobs.get(c.fiza_scope, "not-a-uuid", @now) == {:error, :not_found}
  end
end
