defmodule Core.Leads.GuardTest do
  @moduledoc """
  The duplicate guard, the lead half (AQ-04A §6), across two teams holding
  the same posting: the six answers, the words that name only "another
  team" or "another member", a merged key still answering for its posting,
  and the write that runs it under the advisory lock (409
  `duplicate_application`, `details.existing` as the caller may know it).
  """

  use Core.CoreCase, async: true

  alias Core.Jobs.Check
  alias Core.Leads
  alias Core.Leads.{Change, Guard}

  @now ~U[2026-11-11 09:00:00.000000Z]
  @url "https://careers.bambooinvest.co.uk/jobs/42"

  setup do
    c = board_cast_fixture()
    tanweer = c.tanweer
    {:ok, _link} = Data.Customers.assign_team(tanweer, c.frontend.id, ~D[2026-11-10])
    back = job_fixture(scope_for(c.fiza), team: c.backend, url: @url, title: "Backend Developer")

    front =
      job_fixture(scope_for(c.hira), team: c.frontend, url: @url, title: "Backend Developer")

    elixir = profile_fixture(Data.Customers.get(c.org.id, tanweer.id), title: "Elixir backend")
    golang = Data.Profiles.get(c.golang.id)
    Map.merge(c, %{back: back, front: front, elixir: elixir, golang: golang})
  end

  defp lead(scope, job, profile, as \\ "save") do
    {:ok, sheet} =
      Leads.create(scope, %{"job_id" => job.id, "profile_id" => profile.id, "as" => as}, @now)

    sheet
  end

  defp check(scope, team, profile) do
    {:ok, answer} =
      Check.run(scope, %{"team_id" => team.id, "url" => @url, "profile_id" => profile.id}, @now)

    answer.lead
  end

  test "free: no lead on the posting", c do
    assert %{answer: "free", existing: nil, same_customer: []} =
             check(scope_for(c.fiza), c.backend, c.golang)
  end

  test "saved and refused, in this team, with who and when; elsewhere from the other team, naming nobody",
       c do
    sheet = lead(scope_for(c.fiza), c.back, c.golang)

    assert %{answer: "saved", existing: existing} = check(scope_for(c.qasim), c.backend, c.golang)
    assert existing.lead_id == sheet.id and existing.state == :todo and existing.team == "this"
    assert existing.by.name == "Fiza" and existing.stage == nil

    {:ok, _applied} =
      Core.Leads.Act.run(
        scope_for(c.fiza),
        :apply,
        sheet.id,
        %{"from" => %{"state" => "todo"}},
        @now
      )

    assert %{answer: "refused", existing: %{state: :in_progress, stage: %{key: "applied"}}} =
             check(scope_for(c.hira), c.backend, c.golang)

    assert %{answer: "elsewhere", existing: existing} =
             check(scope_for(c.hira), c.frontend, c.golang)

    assert existing == %{applied_at: existing.applied_at, team: "another"}
    assert existing.applied_at
  end

  test "refused stays refused for an archived lead", c do
    sheet = lead(scope_for(c.fiza), c.back, c.golang, "apply")
    {:ok, _} = Change.flag(scope_for(c.fiza), :archive, sheet.id, @now)
    assert %{answer: "refused"} = check(scope_for(c.fiza), c.backend, c.golang)
  end

  test "warn: another profile of the same customer, in any team; shared: only other customers'",
       c do
    _sheet = lead(scope_for(c.fiza), c.back, c.golang, "apply")

    assert %{answer: "warn", same_customer: [same]} =
             check(scope_for(c.fiza), c.backend, c.elixir)

    assert same.profile.title == "Golang backend" and same.team == "this" and
             same.by.name == "Fiza"

    assert %{answer: "warn", same_customer: [other_team]} =
             check(scope_for(c.hira), c.frontend, c.elixir)

    assert other_team.team == "another" and not Map.has_key?(other_team, :by)

    naveed = profile_fixture(c.naveed, title: "Golang")

    assert %{answer: "shared", existing: nil, same_customer: []} =
             check(scope_for(c.fiza), c.backend, naveed)
  end

  test "a lead the caller may not see is named only as another member", c do
    _sheet = lead(scope_for(c.fiza), c.back, c.golang, "apply")
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})

    assert %{answer: "refused", existing: existing} =
             check(scope_for(c.muaz), c.backend, c.golang)

    assert existing == %{applied_at: existing.applied_at, team: "this"}

    assert {:error, {:duplicate_application, %{existing: refused, message: message}}} =
             Leads.create(
               scope_for(c.muaz),
               %{"job_id" => c.back.id, "profile_id" => c.golang.id, "as" => "save"},
               @now
             )

    refute Map.has_key?(refused, :lead_id)
    assert message =~ "“Golang backend” already has a lead on this job: applied by another member"
  end

  test "the write under the lock: the other team is refused naming only another team (sequential calls)",
       c do
    _first = lead(scope_for(c.fiza), c.back, c.golang, "apply")

    assert {:error, {:duplicate_application, %{existing: existing, message: message}}} =
             Leads.create(
               scope_for(c.hira),
               %{"job_id" => c.front.id, "profile_id" => c.golang.id, "as" => "save"},
               @now
             )

    assert existing == %{applied_at: existing.applied_at, team: "another"}
    assert message =~ "already has a lead on this job in another team, applied"

    assert Guard.refuse(scope_for(c.hira), c.front.canonical_key, c.frontend.id, c.golang) ==
             {:error,
              Guard.duplicate(
                scope_for(c.hira),
                hd(Data.Leads.for_jobs([c.back.id])),
                c.frontend.id,
                c.golang
              )}

    # The lock is taken and released with the transaction.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Guard.lock!(scope_for(c.fiza), c.back.canonical_key, c.golang.id)
             end)
  end

  test "a merged key answers for the posting it was merged into", c do
    sheet = lead(scope_for(c.fiza), c.back, c.golang, "apply")

    other =
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        url: "https://careers.bambooinvest.co.uk/jobs/43"
      )

    {:ok, _} =
      Core.Jobs.Act.merge(scope_for(c.hira), other.id, %{"into_job_id" => c.back.id}, @now)

    {:ok, answer} =
      Check.run(
        scope_for(c.fiza),
        %{
          "team_id" => c.backend.id,
          "url" => "https://careers.bambooinvest.co.uk/jobs/43",
          "profile_id" => c.golang.id
        },
        @now
      )

    assert %{answer: "refused", existing: %{lead_id: id}} = answer.lead
    assert id == sheet.id
  end

  test "the check without a profile answers no lead half; with a foreign profile, not found", c do
    {:ok, answer} =
      Check.run(scope_for(c.fiza), %{"team_id" => c.backend.id, "url" => @url}, @now)

    assert answer.lead == nil

    stranger = profile_fixture(customer_fixture(organisation_fixture(), []))

    assert Check.run(
             scope_for(c.fiza),
             %{"team_id" => c.backend.id, "url" => @url, "profile_id" => stranger.id},
             @now
           ) ==
             {:error, :not_found}
  end
end
