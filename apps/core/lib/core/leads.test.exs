defmodule Core.LeadsTest do
  @moduledoc """
  A lead made (AQ-04A §7 save and apply, §8.1 `POST /leads`): on a pool job
  or a new job in the same transaction, its ledger row, its audit row, its
  notices, the team that serves the customer, the paused customer, the
  pipeline it runs on, and the scoping of a read.
  """

  use Core.CoreCase, async: true

  alias Core.Leads
  alias Data.Audit
  alias Data.Customers.Profile
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")
    Map.put(c, :job, job)
  end

  defp save(scope, job, profile, extra \\ %{}),
    do:
      Leads.create(
        scope,
        Map.merge(%{"job_id" => job.id, "profile_id" => profile.id, "as" => "save"}, extra),
        @now
      )

  describe "save and apply" do
    test "save: To do, no stage, the employment pipeline, a saved event, an audit row", c do
      assert {:ok, sheet} = save(scope_for(c.fiza), c.job, c.golang)
      assert sheet.state == :todo and sheet.stage == nil
      assert sheet.pipeline.key == :employment and sheet.pipeline.version == 1
      assert sheet.owner.user_id == c.fiza.id
      assert sheet.created_by.user_id == c.fiza.id
      assert sheet.progress == %{at: 0, of: 10}
      assert [%{kind: :saved, to_label: "To do", actor: %{kind: :user}}] = sheet.recent
      assert sheet.can.apply and not sheet.can.resume
      assert [%{action: "created"}] = Audit.list_for_subject(c.org.id, "leads", sheet.id)
    end

    test "apply: In progress at the first applied stage, the facts kept, the CV defaulted", c do
      doc = document_fixture(c.golang, kind: :cv, label: "CV")
      {:ok, _} = Data.Profiles.put_default_document(c.golang, doc.id)

      assert {:ok, sheet} =
               save(scope_for(c.fiza), c.job, c.golang, %{
                 "as" => "apply",
                 "applied_at" => "2026-11-10T10:00:00Z",
                 "applied_via" => "external_ats",
                 "cover_letter_md" => "Dear Bamboo",
                 "bid_minor" => 4500,
                 "bid_currency" => "USD",
                 "bid_period" => "hour",
                 "expectation_minor" => 600_000,
                 "expectation_currency" => "GBP",
                 "expectation_period" => "year"
               })

      assert sheet.state == :in_progress
      assert sheet.stage.key == "applied" and sheet.progress == %{at: 2, of: 10}
      assert DateTime.compare(sheet.applied_at, ~U[2026-11-10 10:00:00Z]) == :eq
      assert sheet.applied_via == :external_ats and sheet.applied_confirmation == :by_hand
      assert sheet.applied_by.user_id == c.fiza.id
      assert sheet.cv.id == doc.id
      assert %{min_minor: 4500, max_minor: 4500, currency: "USD", period: :hour} = sheet.bid
      assert %{min_minor: 600_000, currency: "GBP", period: :year} = sheet.expectation
      assert [%{kind: :applied, from_label: nil, to_label: "Applied"}] = sheet.recent
    end

    test "apply refuses a time in the future and half a bid", c do
      assert {:error, {:invalid, %{"applied_at" => _}}} =
               save(scope_for(c.fiza), c.job, c.golang, %{
                 "as" => "apply",
                 "applied_at" => "2027-01-01T00:00:00Z"
               })

      assert {:error, %Ecto.Changeset{} = cs} =
               save(scope_for(c.fiza), c.job, c.golang, %{"as" => "apply", "bid_minor" => 10})

      assert errors_on(cs)[:bid_currency]
    end

    test "a freelance job runs Freelance; the sheet may name the pipeline", c do
      job = job_fixture(scope_for(c.fiza), team: c.backend, engagement: :freelance_hourly)
      assert {:ok, %{pipeline: %{key: :freelance}}} = save(scope_for(c.fiza), job, c.golang)

      job2 = job_fixture(scope_for(c.fiza), team: c.backend)

      assert {:ok, %{pipeline: %{key: :freelance}}} =
               save(scope_for(c.fiza), job2, c.golang, %{"pipeline_key" => "freelance"})

      assert {:error, {:invalid, %{"pipeline_key" => _}}} =
               save(
                 scope_for(c.fiza),
                 job_fixture(scope_for(c.fiza), team: c.backend),
                 c.golang,
                 %{"pipeline_key" => "x"}
               )
    end

    test "owner: someone in the team, told when someone else names them", c do
      assert {:error, {:invalid, %{"owner_user_id" => _}}} =
               save(scope_for(c.fiza), c.job, c.golang, %{"owner_user_id" => user_fixture().id})

      assert {:ok, sheet} =
               save(scope_for(c.fiza), c.job, c.golang, %{"owner_user_id" => c.qasim.id})

      assert sheet.owner.user_id == c.qasim.id

      assert [%{notification_kind_key: "leads.assigned", title: title, link_path: path}] =
               notifications(c.qasim.id)

      assert title =~ "Fiza handed you" and path == "/leads/#{sheet.id}"
    end

    test "with a job body: the job made in the team in the same transaction; P3's check again",
         c do
      body = %{
        "team_id" => c.backend.id,
        "job" => %{"url" => "https://careers.bambooinvest.co.uk/jobs/9", "title" => "Go engineer"},
        "profile_id" => c.golang.id,
        "as" => "save"
      }

      assert {:ok, sheet} = Leads.create(scope_for(c.fiza), body, @now)
      assert sheet.job.title == "Go engineer" and sheet.team.id == c.backend.id

      assert {:error, {:job_exists, %{id: id}}} = Leads.create(scope_for(c.fiza), body, @now)
      assert id == sheet.job.id

      # Neither half is left made without the other: a refused lead leaves no job.
      {:ok, paused} =
        Data.Customers.change_status(
          customer_fixture(c.org, [c.backend]),
          :paused,
          ~D[2026-11-10]
        )

      profile = profile_fixture(paused)

      body = %{
        body
        | "profile_id" => profile.id,
          "job" => %{"url" => "https://x.example.com/jobs/1", "title" => "T"}
      }

      assert {:error, {:invalid, _}} = Leads.create(scope_for(c.fiza), body, @now)
      assert Data.Jobs.get_by_key(c.backend.id, "x.example.com/jobs/1") == nil
    end
  end

  describe "who may make one" do
    test "a team that doesn't serve the customer, in words; another team's job is not found", c do
      imran_profile = profile_fixture(c.imran, title: "AI/ML engineer")

      assert save(scope_for(c.fiza), c.job, imran_profile) ==
               {:error, {:forbidden, "Backend squad doesn't serve Imran."}}

      front_job = job_fixture(scope_for(c.hira), team: c.frontend)
      assert save(scope_for(c.qasim), front_job, c.golang) == {:error, :not_found}

      assert {:error, :not_found} =
               Leads.create(
                 scope_for(c.fiza),
                 %{"job_id" => c.job.id, "profile_id" => Ecto.UUID.generate(), "as" => "save"},
                 @now
               )
    end

    test "a paused customer or profile is refused with words (QP4a-10)", c do
      naveed = Data.Customers.get(c.org.id, c.naveed.id)
      {:ok, _} = Data.Customers.change_status(naveed, :paused, ~D[2026-11-10])
      profile = profile_fixture(c.naveed, title: "Golang")

      assert {:error, {:invalid, %{"profile_id" => [words]}}} =
               save(scope_for(c.fiza), c.job, profile)

      assert words == "Naveed is paused. Resume them before saving or applying for them."

      {:ok, paused_profile} =
        c.tanweer
        |> profile_fixture(title: "Paused one")
        |> Profile.facts_changeset(%{status: :paused})
        |> Repo.update()

      paused_profile = Data.Profiles.get(paused_profile.id)

      assert {:error, {:invalid, %{"profile_id" => [_]}}} =
               save(scope_for(c.fiza), c.job, paused_profile)
    end

    test "the system admin, in no team, makes one in any team", c do
      assert {:ok, sheet} = save(scope_for(c.dawud), c.job, c.golang)
      assert sheet.owner.user_id == c.dawud.id
    end

    test "as: is required, and a lead needs a job", c do
      assert {:error, {:missing, [:as]}} =
               Leads.create(
                 scope_for(c.fiza),
                 %{"job_id" => c.job.id, "profile_id" => c.golang.id},
                 @now
               )

      assert {:error, {:missing, [:job_id]}} =
               Leads.create(
                 scope_for(c.fiza),
                 %{"profile_id" => c.golang.id, "as" => "save"},
                 @now
               )
    end
  end

  describe "reading" do
    test "get answers the sheet to whoever sees it, not found to another team or another org",
         c do
      {:ok, sheet} = save(scope_for(c.fiza), c.job, c.golang)
      assert {:ok, %{id: id}} = Leads.get(scope_for(c.hira), sheet.id, @now)
      assert id == sheet.id

      farah = member_fixture(c.frontend, :member, user_fixture())
      assert Leads.get(scope_for(farah), sheet.id, @now) == {:error, :not_found}

      other = organisation_fixture()
      assert Leads.get(scope_for(admin_fixture(other)), sheet.id, @now) == {:error, :not_found}
      assert Leads.get(scope_for(c.fiza), "nonsense", @now) == {:error, :not_found}
    end

    test "the customer reads their own lead in the customer's view, and nobody else's", c do
      {:ok, sheet} = save(scope_for(c.fiza), c.job, c.golang)
      assert {:ok, view} = Leads.get(customer_scope_for(c.tanweer), sheet.id, @now)
      refute Map.has_key?(view, :owner)
      refute Map.has_key?(view, :team)
      assert view.can == %{applied: true}
      assert Leads.get(customer_scope_for(c.naveed), sheet.id, @now) == {:error, :not_found}
    end
  end

  test "the unique (job, profile) is the backstop: the same pair twice is the 409", c do
    {:ok, _sheet} = save(scope_for(c.fiza), c.job, c.golang)

    assert {:error, {:duplicate_application, %{existing: existing, message: message}}} =
             save(scope_for(c.qasim), c.job, c.golang)

    assert existing.team == "this" and existing.by.name == "Fiza"
    assert message =~ "“Golang backend” already has a lead on this job: saved by Fiza"
    assert length(Store.for_jobs([c.job.id])) == 1
  end

  defp notifications(user_id) do
    import Ecto.Query

    Repo.all(
      from(n in Data.Notifications.Notification,
        where: n.user_id == ^user_id and not is_nil(n.lead_id)
      )
    )
  end
end
