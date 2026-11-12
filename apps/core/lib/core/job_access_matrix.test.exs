defmodule Core.JobAccessMatrixTest do
  @moduledoc """
  AQ-03 §4.3 with AQ-03B §3.2's levels, cell by cell: every chair of the
  cast × three jobs and a company × every action — J1 Fiza's and J2
  Qasim's in Backend squad's pool, J3 Hira's in Frontend squad's — **three
  times**, with both teams' `peer_jobs` at `hidden`, `view` and `edit`.

  The chairs: Dawud (the system admin, in no team), Hira (lead of both), Bilal
  (lead of Backend), Fiza (member of both), Qasim and Muaz (members of
  Backend), the `:admin` chair (Dawud again: one system admin), Farah (a member of Frontend only: the other
  team), the portal scopes of Tanweer and Naveed, and a signed-in stranger
  in no team. A job and a company of another organisation are not found for
  everyone. Then the same answers through the contexts: the per-team pool,
  the check's hidden answer, the 409 that names nobody, merge within a team,
  the company card's open jobs.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Jobs, as: JobAccess
  alias Core.Companies
  alias Core.Jobs
  alias Core.Jobs.{Act, Check, Pool}

  @jobs JobAccess.job_actions()
  @companies JobAccess.company_actions()
  @lead_only [:merge, :archive, :unarchive]
  @change [:edit, :close, :reopen, :dismiss]
  @look [:read, :check, :create]
  @keys [:j1, :j2, :j3]

  @lead %{ok: @jobs}
  # The creator, or a member at `edit`: everything but a lead's merge and archive.
  @changer %{ok: @jobs -- @lead_only, forbidden: @lead_only}
  # A member at `view`: reads, every change refused.
  @viewer %{ok: @look, forbidden: @change ++ @lead_only}
  @hidden %{not_found: @jobs}

  @staff_company %{ok: @companies}
  @no_company %{not_found: @companies}

  @fixed [
    {:dawud, %{j1: @lead, j2: @lead, j3: @lead}},
    {:hira, %{j1: @lead, j2: @lead, j3: @lead}},
    {:bilal, %{j1: @lead, j2: @lead, j3: @hidden}},
    {:admin, %{j1: @lead, j2: @lead, j3: @lead}},
    {:tanweer, %{j1: @hidden, j2: @hidden, j3: @hidden}},
    {:naveed, %{j1: @hidden, j2: @hidden, j3: @hidden}},
    {:stranger, %{j1: @hidden, j2: @hidden, j3: @hidden}}
  ]

  @levels [
    hidden: [
      {:fiza, %{j1: @changer, j2: @hidden, j3: @hidden}},
      {:qasim, %{j1: @hidden, j2: @changer, j3: @hidden}},
      {:muaz, %{j1: @hidden, j2: @hidden, j3: @hidden}},
      {:farah, %{j1: @hidden, j2: @hidden, j3: @hidden}}
    ],
    view: [
      {:fiza, %{j1: @changer, j2: @viewer, j3: @viewer}},
      {:qasim, %{j1: @viewer, j2: @changer, j3: @hidden}},
      {:muaz, %{j1: @viewer, j2: @viewer, j3: @hidden}},
      {:farah, %{j1: @hidden, j2: @hidden, j3: @viewer}}
    ],
    edit: [
      {:fiza, %{j1: @changer, j2: @changer, j3: @changer}},
      {:qasim, %{j1: @changer, j2: @changer, j3: @hidden}},
      {:muaz, %{j1: @changer, j2: @changer, j3: @hidden}},
      {:farah, %{j1: @hidden, j2: @hidden, j3: @changer}}
    ]
  ]

  @now ~U[2026-11-10 09:00:00.000000Z]
  @view_words "You can see this, but only its people or a team lead can change it."

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    # One system admin (QP4a-21): the `:admin` chair is Dawud, in no team.
    admin = c.dawud
    company = company_fixture(c.org, name: "Bamboo Invest")

    jobs = %{
      j1: job_fixture(scope_for(c.fiza), team: c.backend, company: company, title: "J1"),
      j2: job_fixture(scope_for(c.qasim), team: c.backend, company: company, title: "J2"),
      j3: job_fixture(scope_for(c.hira), team: c.frontend, company: company, title: "J3")
    }

    other = organisation_fixture()
    outsider = scope_for(admin_fixture(other))
    foreign_company = company_fixture(other)

    foreign_job =
      job_fixture(outsider, team: team_fixture(other), company: foreign_company)

    Map.merge(c, %{
      farah: farah,
      admin: admin,
      stranger: user_fixture(),
      company: company,
      jobs: jobs,
      foreign_job: foreign_job,
      foreign_company: foreign_company
    })
  end

  defp put_level(c, level) do
    for team <- [c.backend, c.frontend],
        do: {:ok, _settings} = Data.Teams.put_settings(team.id, %{peer_jobs: level})
  end

  defp scope_of(c, who) when who in [:tanweer, :naveed],
    do: customer_scope_for(Map.fetch!(c, who))

  defp scope_of(c, :stranger), do: scope_for(c.stranger, organisation: c.org)
  defp scope_of(c, who), do: scope_for(Map.fetch!(c, who))

  for {level, rows} <- @levels, {who, cells} <- @fixed ++ rows do
    test "#{who}, peer_jobs #{level}", c do
      who = unquote(who)
      put_level(c, unquote(level))
      scope = scope_of(c, who)
      cells = unquote(Macro.escape(cells))

      assert Enum.sort(Map.keys(cells)) == @keys, "#{who} names every job"

      company_cells =
        if who in [:tanweer, :naveed, :stranger], do: @no_company, else: @staff_company

      subjects =
        Enum.map(cells, fn {key, cell} -> {:job, c.jobs[key], @jobs, cell, key} end) ++
          [{:company, c.company, @companies, company_cells, :company}]

      for {kind, subject, all, expected, key} <- subjects do
        table =
          for {outcome, actions} <- expected, action <- actions, into: %{}, do: {action, outcome}

        assert Enum.sort(Map.keys(table)) == Enum.sort(all), "#{who}/#{key} names every action"

        for {action, outcome} <- table do
          got = Access.why_not(scope, action, {kind, subject})

          assert classify(got) == outcome,
                 "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"
        end
      end

      # Another organisation's job and company: not found, whatever the role.
      for action <- @jobs,
          do: assert(Access.why_not(scope, action, {:job, c.foreign_job}) == {:error, :not_found})

      for action <- @companies,
          do:
            assert(
              Access.why_not(scope, action, {:company, c.foreign_company}) == {:error, :not_found}
            )

      # The pool lists, per team, exactly the jobs the rule reads.
      for team <- [c.backend, c.frontend] do
        readable =
          for {key, cell} <- cells,
              :read in Map.get(cell, :ok, []),
              c.jobs[key].team_id == team.id,
              do: c.jobs[key].id

        case Pool.list(scope, %{"team_id" => team.id}, @now) do
          {:ok, %{items: items}} ->
            assert Enum.sort(Enum.map(items, & &1.id)) == Enum.sort(readable),
                   "#{who} lists in #{team.name} what they read"

          {:error, :not_found} ->
            assert readable == [], "#{who} reads a job of a pool they cannot list"
        end
      end
    end
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, {:forbidden, words}}) when is_binary(words), do: :forbidden

  # ── Through the contexts ────────────────────────────────────────────────────

  test "the words: a lead's merge and archive; a member at view hears the level's", c do
    put_level(c, :view)
    muaz = scope_for(c.muaz)
    words = {:error, {:forbidden, "Only a lead can merge or archive a job."}}

    assert Act.merge(muaz, c.jobs.j2.id, %{into_job_id: c.jobs.j1.id}, @now) == words
    assert Act.archive(muaz, c.jobs.j1.id, @now) == words
    assert Act.unarchive(muaz, c.jobs.j1.id, @now) == words

    assert Act.close(muaz, c.jobs.j1.id, %{from: "open", reason: "filled"}, @now) ==
             {:error, {:forbidden, @view_words}}

    assert {:ok, %{can: %{merge: false, edit: false, close: false, share: true}}} =
             Jobs.get(muaz, c.jobs.j1.id, @now)

    put_level(c, :edit)

    assert {:ok, %{can: %{merge: false, archive: false, edit: true, close: true}}} =
             Jobs.get(scope_for(c.muaz), c.jobs.j1.id, @now)

    assert {:ok, %{can: %{merge: true, archive: true}}} =
             Jobs.get(scope_for(c.hira), c.jobs.j1.id, @now)
  end

  test "the team: required, the caller's own (any for an admin), else 404", c do
    fiza = scope_for(c.fiza)
    qasim = scope_for(c.qasim)
    url = %{"url" => "https://acme.io/jobs/1", "title" => "Go"}
    required = {:error, {:invalid, %{"team_id" => ["is required"]}}}

    assert Pool.list(fiza, %{}, @now) == required
    assert Check.run(fiza, url, @now) == required
    assert Jobs.create(fiza, url, @now) == required

    frontend = %{"team_id" => c.frontend.id}
    assert Pool.list(qasim, frontend, @now) == {:error, :not_found}
    assert Check.run(qasim, Map.merge(url, frontend), @now) == {:error, :not_found}
    assert Jobs.create(qasim, Map.merge(url, frontend), @now) == {:error, :not_found}
    assert {:ok, _page} = Pool.list(scope_for(c.admin), frontend, @now)
  end

  test "the same link in two pools: each team its own copy, and the check says new in the other",
       c do
    hira = scope_for(c.hira)
    link = %{"url" => c.jobs.j1.source_url, "title" => "Again"}

    assert {:ok, %{state: "in_pool", hidden: false, job: %{id: id}}} =
             Check.run(hira, Map.put(link, "team_id", c.backend.id), @now)

    assert id == c.jobs.j1.id

    frontend = Map.put(link, "team_id", c.frontend.id)
    assert {:ok, %{state: "new"}} = Check.run(hira, frontend, @now)
    assert {:ok, copy} = Jobs.create(hira, frontend, @now)
    assert copy.id != c.jobs.j1.id and copy.team == %{id: c.frontend.id, name: "Frontend squad"}
    assert copy.canonical_key == c.jobs.j1.canonical_key
  end

  test "a teammate's job at hidden: the check and the 409 say only that the team holds it", c do
    put_level(c, :hidden)
    muaz = scope_for(c.muaz)
    link = %{"url" => c.jobs.j1.source_url, "title" => "Mine now", "team_id" => c.backend.id}

    assert Check.run(muaz, link, @now) ==
             {:ok,
              %{
                state: "in_pool",
                key: c.jobs.j1.canonical_key,
                source: c.jobs.j1.source,
                job: nil,
                hidden: true,
                merged_from: nil,
                lead: nil
              }}

    assert Jobs.create(muaz, link, @now) == {:error, {:job_exists, :hidden}}
    assert {:error, {:job_exists, %{id: id}}} = Jobs.create(scope_for(c.hira), link, @now)
    assert id == c.jobs.j1.id
  end

  test "merge stays inside a team: another team's job is 422 into_job_id", c do
    hira = scope_for(c.hira)

    assert Act.merge(hira, c.jobs.j2.id, %{into_job_id: c.jobs.j3.id}, @now) ==
             {:error, {:invalid, %{"into_job_id" => ["is in another team"]}}}

    assert {:ok, %{id: id}} = Act.merge(hira, c.jobs.j2.id, %{into_job_id: c.jobs.j1.id}, @now)
    assert id == c.jobs.j1.id
  end

  test "the company card lists the open jobs of the caller's teams they may see", c do
    titles = fn scope ->
      {:ok, card} = Companies.get(scope, c.company.id)
      card.open_jobs |> Enum.map(& &1.title) |> Enum.sort()
    end

    assert titles.(scope_for(c.qasim)) == ["J1", "J2"]
    assert titles.(scope_for(c.farah)) == ["J3"]
    assert titles.(scope_for(c.admin)) == ["J1", "J2", "J3"]

    put_level(c, :hidden)
    assert titles.(scope_for(c.qasim)) == ["J2"]
  end

  test "suggestions are the profiles of the customers the job's team serves", c do
    imrans = profile_fixture(c.imran, title: "Vue developer")

    assert {:ok, suggestions} = Jobs.suggestions(scope_for(c.hira), c.jobs.j1.id, @now)
    ids = Enum.map(suggestions, & &1.profile.id)
    assert c.golang.id in ids
    refute imrans.id in ids

    assert {:ok, suggestions} = Jobs.suggestions(scope_for(c.hira), c.jobs.j3.id, @now)
    assert Enum.map(suggestions, & &1.profile.id) == [imrans.id]
  end

  test "another organisation's job reads not found, even for that organisation's lookalike role",
       c do
    for who <- [:dawud, :hira, :fiza, :admin, :tanweer] do
      scope = scope_of(c, who)
      assert Jobs.get(scope, c.foreign_job.id, @now) == {:error, :not_found}
      assert Companies.get(scope, c.foreign_company.id) == {:error, :not_found}
    end
  end

  test "the customer has no list, no check and no company picker", c do
    tanweer = customer_scope_for(c.tanweer)
    backend = %{"team_id" => c.backend.id}
    assert Pool.list(tanweer, backend, @now) == {:error, :not_found}

    assert Check.run(tanweer, Map.put(backend, "url", "https://acme.io/jobs/1"), @now) ==
             {:error, :not_found}

    assert Companies.search(tanweer, nil) == {:error, :not_found}

    assert Jobs.create(tanweer, Map.merge(backend, %{"url" => "https://acme.io/jobs/1"}), @now) ==
             {:error, :not_found}
  end
end
