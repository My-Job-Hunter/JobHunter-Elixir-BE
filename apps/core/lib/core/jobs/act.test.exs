defmodule Core.Jobs.ActTest do
  @moduledoc """
  The verbs on a job (AQ-03 §7, §8): close and reopen with `from` (a stale
  one is `job_moved`), archive and unarchive by a lead, merge — blanks
  filled, skills united, snapshots, details and dismissals moved, earlier
  merges re-pointed, the merged job gone and its link resolving to the
  survivor — and dismissals. Each leaves its audit row.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs.{Act, Check}
  alias Data.Audit
  alias Data.JobParts

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    Map.merge(cast, %{fiza_scope: scope_for(cast.fiza), hira_scope: scope_for(cast.hira)})
  end

  defp actions(job, org),
    do: Enum.map(Audit.list_for_subject(org.id, "jobs", job.id), & &1.action)

  describe "close and reopen" do
    test "close with the status seen, then reopen; each audited", c do
      job = job_fixture(c.fiza_scope)
      qasim = scope_for(c.qasim)

      assert {:ok,
              %{
                status: :closed,
                close_reason: :filled,
                closed_at: @now,
                can: %{reopen: true, close: false}
              }} =
               Act.close(qasim, job.id, %{from: "open", reason: "filled"}, @now)

      assert {:ok, %{status: :open, close_reason: nil, closed_at: nil}} =
               Act.reopen(qasim, job.id, %{"from" => "closed"}, @now)

      assert actions(job, c.org) == ["closed", "reopened"]
    end

    test "a stale from is job_moved with the job as it is now", c do
      job = job_fixture(c.fiza_scope)
      {:ok, _sheet} = Act.close(c.fiza_scope, job.id, %{from: "open", reason: "expired"}, @now)
      {:ok, _sheet} = Act.reopen(c.fiza_scope, job.id, %{from: "closed"}, @now)

      # A second tab still shows it closed.
      assert {:error, {:job_moved, %{status: :open}}} =
               Act.reopen(scope_for(c.qasim), job.id, %{from: "closed"}, @now)

      assert {:error, {:job_moved, %{status: :open}}} =
               Act.close(scope_for(c.qasim), job.id, %{from: "closed", reason: "filled"}, @now)
    end

    test "from and reason are required, and from the vocabulary", c do
      job = job_fixture(c.fiza_scope)

      assert Act.close(c.fiza_scope, job.id, %{reason: "filled"}, @now) ==
               {:error, {:missing, [:from]}}

      assert Act.close(c.fiza_scope, job.id, %{from: "open"}, @now) ==
               {:error, {:missing, [:reason]}}

      assert Act.close(c.fiza_scope, job.id, %{from: "open", reason: "bored"}, @now) ==
               {:error, {:invalid, %{"reason" => ["is not one of the reasons"]}}}

      assert Act.reopen(c.fiza_scope, job.id, %{from: "open"}, @now) ==
               {:error, {:invalid, %{"from" => ["the job is not closed"]}}}
    end
  end

  describe "archive" do
    test "a lead archives and unarchives; a member is refused with §4.2's words", c do
      job = job_fixture(c.fiza_scope)

      assert Act.archive(scope_for(c.muaz), job.id, @now) ==
               {:error, {:forbidden, "Only a lead can merge or archive a job."}}

      assert {:ok, %{archived_at: @now, can: %{archive: false, unarchive: true}}} =
               Act.archive(scope_for(c.bilal), job.id, @now)

      assert {:ok, %{archived_at: nil}} = Act.unarchive(scope_for(c.bilal), job.id, @now)
      assert actions(job, c.org) == ["archived", "unarchived"]
    end
  end

  describe "merge (§8)" do
    setup c do
      go = skill_fixture(c.org, name: "Go")
      pg = skill_fixture(c.org, name: "PostgreSQL")
      fennec = company_fixture(c.org, name: "Fennec Cloud")

      survivor =
        job_fixture(c.fiza_scope,
          url: "https://www.linkedin.com/jobs/view/4012233871",
          title: "Senior Node.js Engineer",
          company: fennec,
          workplace: :remote,
          skills: [{go, false}],
          platform_details: %{is_easy_apply: true}
        )

      merged =
        job_fixture(c.fiza_scope,
          url: "https://fennec.cloud/careers/node",
          title: "Node.js Engineer",
          workplace: :hybrid,
          description_md: "Build the platform.",
          apply_url: "https://fennec.cloud/careers/node/apply",
          comp_min_minor: 500_000,
          comp_currency: "USD",
          comp_period: :month,
          skills: [{go, true}, {pg, true}]
        )

      Map.merge(c, %{go: go, pg: pg, survivor: survivor, merged: merged})
    end

    test "fills the survivor's blanks, unites skills, deletes the merged job; its link resolves",
         c do
      %{survivor: survivor, merged: merged} = c

      {:ok, _snapshot} =
        JobParts.add_snapshot(%{
          job_id: merged.id,
          captured_at: @now,
          origin: :manual,
          content_type: :text,
          body: "Posting"
        })

      golang = c.golang

      {:ok, _d} =
        JobParts.put_dismissal(%{
          job_id: merged.id,
          profile_id: golang.id,
          reason: :money,
          dismissed_at: @now
        })

      assert {:ok, sheet} = Act.merge(c.hira_scope, merged.id, %{into_job_id: survivor.id}, @now)

      assert sheet.id == survivor.id
      # Kept its own values; gained the empty ones.
      assert sheet.workplace == :remote
      assert sheet.description_md == "Build the platform."
      assert sheet.apply_url == "https://fennec.cloud/careers/node/apply"
      assert %{min_minor: 500_000, currency: "USD", period: :month} = sheet.money
      assert sheet.platform_details.is_easy_apply == true

      assert [%{name: "Go", is_required: true}, %{name: "PostgreSQL", is_required: true}] =
               sheet.skills

      assert [%{origin: :manual}] = sheet.snapshots

      assert [
               %{
                 title: "Node.js Engineer",
                 source_url: "https://fennec.cloud/careers/node",
                 by: %{name: "Hira Khan"}
               }
             ] =
               sheet.merged_from

      assert [%{profile_id: profile_id}] = JobParts.dismissals(survivor.id)
      assert profile_id == golang.id

      assert Data.Jobs.get(c.org.id, merged.id) == nil

      assert {:merged, %{id: id}, _merge} =
               Check.existing(c.backend.id, "fennec.cloud/careers/node")

      assert id == survivor.id

      assert [%{action: "merged", before: before, after: after_}] =
               Audit.list_for_subject(c.org.id, "jobs", survivor.id)

      assert before["merged_job_id"] == merged.id and after_["into_job_id"] == survivor.id
      assert "description_md" in after_["filled"]
    end

    test "every link merged into the merged job follows it to the new survivor", c do
      %{survivor: survivor, merged: merged} = c

      third =
        job_fixture(c.fiza_scope, url: "https://jobs.lever.co/fennec/abc/apply", title: "Node")

      {:ok, _sheet} = Act.merge(c.hira_scope, third.id, %{into_job_id: merged.id}, @now)
      {:ok, sheet} = Act.merge(c.hira_scope, merged.id, %{into_job_id: survivor.id}, @now)

      assert Enum.map(sheet.merged_from, & &1.title) |> Enum.sort() == [
               "Node",
               "Node.js Engineer"
             ]

      assert {:merged, %{id: id}, _merge} = Check.existing(c.backend.id, "lever:fennec/abc")
      assert id == survivor.id
    end

    test "a dismissal the survivor has for that profile is kept, the merged job's dropped", c do
      %{survivor: survivor, merged: merged} = c
      golang = c.golang

      {:ok, _d} =
        JobParts.put_dismissal(%{
          job_id: survivor.id,
          profile_id: golang.id,
          reason: :skills,
          dismissed_at: @now
        })

      {:ok, _d} =
        JobParts.put_dismissal(%{
          job_id: merged.id,
          profile_id: golang.id,
          reason: :money,
          dismissed_at: @now
        })

      {:ok, _sheet} = Act.merge(c.hira_scope, merged.id, %{into_job_id: survivor.id}, @now)
      assert [%{reason: :skills}] = JobParts.dismissals(survivor.id)
    end

    test "only a lead merges; a job does not merge into itself", c do
      %{survivor: survivor, merged: merged} = c

      assert Act.merge(scope_for(c.muaz), merged.id, %{into_job_id: survivor.id}, @now) ==
               {:error, {:forbidden, "Only a lead can merge or archive a job."}}

      assert Act.merge(c.hira_scope, merged.id, %{into_job_id: merged.id}, @now) ==
               {:error, {:invalid, %{"into_job_id" => ["is this job"]}}}

      assert Act.merge(c.hira_scope, merged.id, %{}, @now) == {:error, {:missing, [:into_job_id]}}
    end
  end

  describe "dismissals" do
    test "Not for this profile, with why; taken back; each audited", c do
      job = job_fixture(c.fiza_scope)

      assert {:ok, sheet} =
               Act.dismiss(
                 c.fiza_scope,
                 job.id,
                 %{profile_id: c.golang.id, reason: "money", note: "Too low"},
                 @now
               )

      assert [%{dismissed: %{reason: :money, note: "Too low", by: %{name: "Fiza"}}}] =
               sheet.suggestions

      assert {:ok, %{suggestions: []}} = Act.undismiss(c.fiza_scope, job.id, c.golang.id, @now)
      assert Act.undismiss(c.fiza_scope, job.id, c.golang.id, @now) == {:error, :not_found}
      assert actions(job, c.org) == ["dismissed", "undismissed"]
    end

    test "a profile the caller may not read is not found", c do
      job = job_fixture(c.fiza_scope)
      imrans = profile_fixture(c.imran, title: "React")

      assert Act.dismiss(
               scope_for(c.muaz),
               job.id,
               %{profile_id: imrans.id, reason: "skills"},
               @now
             ) ==
               {:error, :not_found}
    end
  end
end
