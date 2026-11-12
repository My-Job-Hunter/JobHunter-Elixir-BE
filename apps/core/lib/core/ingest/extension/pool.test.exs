defmodule Core.Ingest.Extension.PoolTest do
  @moduledoc """
  AQ-05 §10.2 (P5.3): a capture of a pool job twice — blanks filled once,
  a person's edit kept, one snapshot, a signals row only on change — and
  at `peer_jobs: view` only *last seen* and the signals; a key not in the
  pool and a job the caller may not see write nothing.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Ingest.Extension
  alias Data.JobParts
  alias Data.Jobs, as: JobStore

  @now ~U[2026-11-11 09:00:00.000000Z]
  @linkedin "https://www.linkedin.com/jobs/view/4012233871/"
  @upwork "https://www.upwork.com/jobs/Go-developer_~01aa11bb22cc33dd44/"
  @fields %{"title" => "Senior Go Engineer", "workplace_text" => "Remote"}

  setup do
    c = board_cast_fixture()
    ext = fn user -> %{scope_for(user) | via: :extension} end
    Map.merge(c, %{ext: ext, sf: ext.(c.fiza), sm: ext.(c.muaz)})
  end

  # ── Capture ─────────────────────────────────────────────────────────────────

  describe "capture" do
    test "a key not in the pool: not_in_pool, nothing written", c do
      params = %{"team_id" => c.backend.id, "url" => @linkedin, "fields" => @fields}
      assert {:ok, %{state: "not_in_pool"}} = Extension.capture(c.sf, params, @now)
      refute Repo.exists?(Data.Jobs.Job)
    end

    test "a pool job twice: blanks filled once, a person's edit kept, one snapshot, signals on change",
         c do
      job =
        job_fixture(scope_for(c.fiza), team: c.backend, url: @upwork, title: "Go dev (edited)")

      params = %{"team_id" => c.backend.id, "url" => @upwork}

      fields = %{
        "title" => "Go developer",
        "location_text" => "Worldwide",
        "description_html" => "<p>Go</p>",
        "upwork" => %{"proposals_text" => "10 to 15", "experience_text" => "Expert"}
      }

      assert {:ok, first} = Extension.capture(c.sf, Map.put(params, "fields", fields), @now)
      assert first.state == "refreshed"
      assert "workplace" in first.filled and "remote_scope" in first.filled
      refute "title" in first.filled
      assert first.signals.count == 1

      job = JobStore.reload(job)
      assert job.title == "Go dev (edited)"
      assert job.workplace == :remote
      assert job.description_html == "<p>Go</p>"
      assert job.last_seen_at == @now
      assert job.last_activity_at == @now
      assert %{experience_level: :expert} = JobParts.get_details(job)

      # The same page again: nothing new.
      assert {:ok, again} = Extension.capture(c.sf, Map.put(params, "fields", fields), @now)
      assert again.filled == [] and again.signals.count == 1
      assert [_one] = Repo.all(from(s in Data.Jobs.Snapshot, where: s.job_id == ^job.id))

      # Proposals 15–20: one new signals row.
      moved = put_in(fields, ["upwork", "proposals_text"], "15 to 20")

      assert {:ok, %{signals: %{count: 2, latest: %{proposals_min: 15}}}} =
               Extension.capture(c.sf, Map.put(params, "fields", moved), @now)
    end

    test "at peer_jobs view only last seen and the signals move", c do
      job = job_fixture(scope_for(c.qasim), team: c.backend, url: @upwork)
      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_jobs: :view})
      muaz = c.ext.(c.muaz)
      later = DateTime.add(@now, 3600, :second)

      fields = %{"location_text" => "Worldwide", "upwork" => %{"proposals_text" => "5 to 10"}}

      assert {:ok, %{filled: [], signals: %{count: 1}}} =
               Extension.capture(
                 muaz,
                 %{"team_id" => c.backend.id, "url" => @upwork, "fields" => fields},
                 later
               )

      job2 = JobStore.reload(job)
      assert job2.workplace == nil
      assert job2.last_seen_at == later
      assert job2.last_activity_at == job.last_activity_at
      assert Repo.all(from(s in Data.Jobs.Snapshot, where: s.job_id == ^job.id)) == []
    end

    test "a teammate's job hidden from the caller: hidden, nothing written", c do
      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_jobs: :hidden})
      job_fixture(scope_for(c.qasim), team: c.backend, url: @upwork)

      assert {:ok, %{state: "hidden"}} =
               Extension.capture(
                 c.ext.(c.muaz),
                 %{"team_id" => c.backend.id, "url" => @upwork, "fields" => %{}},
                 @now
               )
    end
  end
end
