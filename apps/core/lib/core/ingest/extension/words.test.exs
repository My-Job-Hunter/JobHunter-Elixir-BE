defmodule Core.Ingest.Extension.WordsTest do
  @moduledoc """
  AQ-05 §10.5, §11.4 (P5.3): the lookup through the panel's route — P3's
  check, the guard's six answers, and the banner the server words, the
  lead half's answer over the job's — and what the panel may offer.
  """

  use Core.CoreCase, async: true

  alias Core.Ingest.Extension

  @now ~U[2026-11-11 09:00:00.000000Z]
  @linkedin "https://www.linkedin.com/jobs/view/4012233871/"

  setup do
    c = board_cast_fixture()
    ext = fn user -> %{scope_for(user) | via: :extension} end
    Map.merge(c, %{ext: ext, sf: ext.(c.fiza), sm: ext.(c.muaz)})
  end

  defp lookup(scope, team, url, profile \\ nil) do
    params = %{"url" => url, "team_id" => team.id, "profile_id" => profile && profile.id}
    {:ok, lookup} = Extension.lookup(scope, params, @now)
    lookup
  end

  # ── Lookup ──────────────────────────────────────────────────────────────────

  describe "lookup: P3's check and the server's banner" do
    test "not a job", c do
      l = lookup(c.sf, c.backend, "https://www.linkedin.com/feed/")
      assert l.check.state == "invalid"
      assert l.banner == %{tone: "info", words: "This page isn't a job we can read."}
      assert l.can == %{save: false, apply: false, apply_again: false}
      assert l.key == nil
    end

    test "a new job, from the address alone", c do
      l = lookup(c.sf, c.backend, @linkedin)
      assert {l.key, l.source} == {"linkedin:4012233871", :linkedin}
      assert l.banner == %{tone: "ok", words: "New job."}
      assert l.can == %{save: true, apply: true, apply_again: false}
      assert l.lead == nil and l.lead_id == nil
    end

    test "in the pool", c do
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        url: @linkedin,
        first_seen_at: ~U[2026-11-03 10:00:00Z]
      )

      l = lookup(c.sf, c.backend, @linkedin)
      assert l.check.state == "in_pool"
      assert l.banner == %{tone: "ok", words: "In the pool, first seen 3 Nov."}
    end

    test "a teammate's job at peer_jobs hidden: named to nobody, nothing offered", c do
      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_jobs: :hidden})
      job_fixture(scope_for(c.qasim), team: c.backend, url: @linkedin)
      fiza = c.ext.(c.fiza)

      l = lookup(fiza, c.backend, @linkedin, c.golang)

      assert l.banner.words ==
               "That link is already in this team's pool, added by another member."

      assert l.can.save == false
    end

    test "a team one is not in is not found", c do
      assert Extension.lookup(c.sm, %{"url" => @linkedin, "team_id" => c.frontend.id}, @now) ==
               {:error, :not_found}
    end
  end

  describe "lookup: the guard's six answers" do
    setup c do
      job =
        job_fixture(scope_for(c.fiza),
          team: c.backend,
          url: @linkedin,
          title: "Senior Go Engineer"
        )

      %{job: job}
    end

    test "free", c do
      l = lookup(c.sf, c.backend, @linkedin, c.golang)
      assert l.lead.answer == "free"
      assert l.banner.tone == "ok"
      assert l.can == %{save: true, apply: true, apply_again: false}
    end

    test "shared: only another customer's lead", c do
      lead_fixture(scope_for(c.fiza), job: c.job, profile: profile_fixture(c.sara))
      l = lookup(c.sf, c.backend, @linkedin, c.golang)
      assert l.lead.answer == "shared"
      assert l.banner.tone == "ok"
      assert l.can.save
    end

    test "warn: another profile of the same customer applied", c do
      other = profile_fixture(c.tanweer, title: "Elixir backend")

      lead_fixture(scope_for(c.fiza),
        job: c.job,
        profile: other,
        state: :in_progress,
        applied_at: ~U[2026-10-12 10:00:00Z]
      )

      l = lookup(c.sf, c.backend, @linkedin, c.golang)
      assert l.lead.answer == "warn"

      assert l.banner == %{
               tone: "warn",
               words: "Tanweer applied as “Elixir backend” on 12 Oct (Fiza)."
             }

      assert l.can.save and l.can.apply
    end

    test "saved: I applied applies that lead", c do
      lead = lead_fixture(scope_for(c.fiza), job: c.job, profile: c.golang)
      l = lookup(c.sf, c.backend, @linkedin, c.golang)

      assert l.lead.answer == "saved"
      assert l.banner.tone == "info"
      assert l.banner.words =~ ~r/^Already saved for “Golang backend” by Fiza, \d+ \w+\.$/
      assert l.can == %{save: false, apply: true, apply_again: false}
      assert l.lead_id == lead.id
    end

    test "refused: Apply again… where one may change the lead", c do
      lead_fixture(scope_for(c.fiza),
        job: c.job,
        profile: c.golang,
        state: :in_progress,
        applied_at: ~U[2026-10-12 10:00:00Z]
      )

      l = lookup(c.sf, c.backend, @linkedin, c.golang)

      assert l.lead.answer == "refused"

      assert l.banner == %{
               tone: "refused",
               words:
                 "Already applied as “Golang backend” by Fiza, 12 Oct. Now: In progress · Applied."
             }

      assert l.can == %{save: false, apply: false, apply_again: true}

      # A member who may only see it: "another member", nothing to press.
      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
      muaz = c.ext.(c.muaz)
      l = lookup(muaz, c.backend, @linkedin, c.golang)
      assert l.banner.words == "Already applied as “Golang backend” by another member, 12 Oct."
      assert l.can == %{save: false, apply: false, apply_again: false}
      assert l.lead_id == nil
    end

    test "elsewhere: the profile's lead in another team", c do
      {:ok, _} = Data.Customers.assign_team(c.tanweer, c.frontend.id, ~D[2026-11-11])
      front = job_fixture(scope_for(c.hira), team: c.frontend, url: @linkedin)

      lead_fixture(scope_for(c.hira),
        job: front,
        profile: c.golang,
        state: :in_progress,
        applied_at: ~U[2026-10-12 10:00:00Z]
      )

      l = lookup(c.sf, c.backend, @linkedin, c.golang)
      assert l.lead.answer == "elsewhere"

      assert l.banner == %{
               tone: "refused",
               words:
                 "“Golang backend” already has a lead on this job in another team (applied 12 Oct). " <>
                   "That team carries it."
             }

      assert l.can == %{save: false, apply: false, apply_again: false}
    end
  end
end
