defmodule Core.RetentionTest do
  @moduledoc """
  AQ-04B §7 done, each sweep **run twice** (the second finds nothing): the
  warning once per quiet spell; the archive of quiet leads (the hired one
  and the held one stay) and of a job with only archived leads (a shared
  job with a live lead stays); the purge with its fingerprint first, its
  tasks unlinked and not deleted, its notifications, notes and labels gone,
  then a bare job; the guard's tombstone answer and *Apply again…* after
  it; the preview from each chair; `run_all/1` in order.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Leads
  alias Core.Leads.{Change, Guard, Words}
  alias Core.Retention
  alias Data.Leads, as: Store
  alias Data.Leads.Lead

  @t0 ~U[2026-11-01 09:00:00.000000Z]

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    bamboo = company_fixture(c.org, name: "Bamboo Invest")

    job = job_fixture(fiza, team: c.backend, title: "Backend Developer", company: bamboo)
    shared = job_fixture(fiza, team: c.backend, title: "Shared job")
    quiet_job(job)
    quiet_job(shared)

    quiet = lead_fixture(fiza, job: job, profile: c.golang, as: :apply, last_activity_at: @t0)

    Map.merge(c, %{fiza_scope: fiza, job: job, shared: shared, quiet: quiet})
  end

  defp quiet_job(job, at \\ @t0) do
    Repo.update_all(from(j in Data.Jobs.Job, where: j.id == ^job.id),
      set: [last_activity_at: at, first_seen_at: at]
    )
  end

  defp kinds(lead_id), do: lead_id |> Store.events() |> Enum.map(& &1.kind)

  defp notes(user_id, kind) do
    Repo.all(
      from(n in Data.Notifications.Notification,
        where: n.user_id == ^user_id and n.notification_kind_key == ^kind
      )
    )
  end

  describe "the warning" do
    test "at 83 quiet days, one event and one bell; a second sweep adds nothing", c do
      assert Retention.warn(day(82)) == %{warned: 0}
      assert Retention.warn(day(83)) == %{warned: 1}
      assert Retention.warn(day(83)) == %{warned: 0}

      assert kinds(c.quiet.id) == [:archive_warned]
      [warned] = Store.events(c.quiet.id)
      assert warned.actor_kind == :system and warned.visibility == :staff
      assert warned.to_label == "30 Jan"

      assert [note] = notes(c.fiza.id, "leads.archive_warned")

      assert note.title ==
               "“Backend Developer · Bamboo Invest” (Golang backend) archives on 30 Jan. " <>
                 "Open it or pin it to keep it."

      # System events are not activity.
      assert Store.reload(c.quiet).last_activity_at == @t0
    end

    test "a touch after the warning earns a fresh one 83 days later, not none", c do
      assert %{warned: 1} = Retention.warn(day(83))

      Repo.update_all(from(l in Lead, where: l.id == ^c.quiet.id),
        set: [last_activity_at: day(84)]
      )

      assert %{warned: 0} = Retention.warn(day(100))
      assert %{warned: 1} = Retention.warn(day(167))
      assert length(notes(c.fiza.id, "leads.archive_warned")) == 2
    end
  end

  describe "the archive" do
    test "quiet leads archive; the hired, the held and the shared job's live lead stay; twice",
         c do
      hired =
        lead_fixture(c.fiza_scope,
          job: c.shared,
          state: :done,
          outcome: :hired,
          is_pinned: true,
          last_activity_at: @t0
        )

      held =
        lead_fixture(c.fiza_scope,
          job: job_fixture(c.fiza_scope, team: c.backend),
          state: :on_hold,
          hold_until_on: ~D[2026-12-01],
          last_activity_at: @t0
        )

      assert Retention.archive(day(90)) == %{leads: 1, jobs: 1}
      assert Retention.archive(day(90)) == %{leads: 0, jobs: 0}

      quiet = Store.reload(c.quiet)
      assert quiet.archived_at == day(90) and quiet.archive_reason == :inactive
      assert quiet.state == :in_progress
      assert :archived in kinds(quiet.id)
      assert [note] = notes(c.fiza.id, "leads.archived")
      assert note.title == "“Backend Developer · Bamboo Invest” was archived after 90 quiet days."

      assert Data.Jobs.reload(c.job).archived_at == day(90)
      assert is_nil(Data.Jobs.reload(c.shared).archived_at)
      assert is_nil(Store.reload(hired).archived_at)
      assert is_nil(Store.reload(held).archived_at)

      # The held lead's clock starts at the end of its until day.
      assert %{leads: 1} = Retention.archive(~U[2027-03-02 00:00:00.000000Z])
      refute is_nil(Store.reload(held).archived_at)
    end

    test "unarchive restarts the clock: back to its state, nothing more for 90 days", c do
      %{leads: 1} = Retention.archive(day(90))
      {:ok, _sheet} = Change.flag(c.fiza_scope, :unarchive, c.quiet.id, day(91))

      quiet = Store.reload(c.quiet)
      assert is_nil(quiet.archived_at) and quiet.state == :in_progress
      assert quiet.last_activity_at == day(91)
      assert is_nil(Data.Jobs.reload(c.job).archived_at)
      assert Retention.archive(day(180)) == %{leads: 0, jobs: 0}
    end
  end

  describe "the purge" do
    setup c do
      # The lead and its job, and the pool job nobody pursued.
      %{leads: 1, jobs: 2} = Retention.archive(day(90))

      task =
        task_fixture(c.fiza_scope,
          team: c.backend,
          customer: c.tanweer,
          lead_id: c.quiet.id,
          title: "Send the portfolio link"
        )

      _note = note_fixture(c.fiza_scope, c.quiet)
      label = label_fixture(c.fiza_scope, c.backend, name: "Priority client")
      Data.Labels.put_for_lead(c.quiet.id, [label.id])

      {:ok, _link} =
        Core.ShareLinks.create(
          c.fiza_scope,
          {:lead, c.quiet.id},
          %{"level" => "summary"},
          day(90)
        )

      Map.put(c, :task, task)
    end

    test "a fingerprint first, then the lead and what hangs on it; tasks unlinked; twice", c do
      assert notes(c.fiza.id, "leads.archived") != []

      assert Retention.purge(day(179)) == %{leads: 0, jobs: 0}
      assert Retention.purge(day(180)) == %{leads: 1, jobs: 2}
      assert Retention.purge(day(180)) == %{leads: 0, jobs: 0}

      assert Repo.get(Lead, c.quiet.id) == nil
      assert Repo.get(Data.Jobs.Job, c.job.id) == nil

      [print] = Repo.all(Data.Leads.Fingerprint)
      assert print.profile_id == c.golang.id and print.customer_id == c.tanweer.id
      assert print.canonical_key == c.job.canonical_key and print.team_id == c.backend.id
      assert print.stage_kinds == [:applied]
      # The organisation's day (Asia/Karachi), not UTC's: after 19:00 UTC they differ.
      assert print.applied_on == Retention.Policy.day(c.quiet.applied_at, c.org.timezone)

      task = Repo.get!(Data.Tasks.Task, c.task.id)
      assert task.lead_id == nil

      assert notes(c.fiza.id, "leads.archived") == []
      assert Repo.all(Data.Leads.Note) == []
      assert Repo.all(Data.Labels.LeadLabel) == []
      assert Repo.all(from(s in Data.ShareLinks.ShareLink, where: s.lead_id == ^c.quiet.id)) == []
      assert Repo.all(from(e in Data.Leads.Event, where: e.lead_id == ^c.quiet.id)) == []

      [audit] = Data.Audit.list_for_subject(c.org.id, "leads", c.quiet.id) |> Enum.take(-1)
      assert audit.action == "purged" and audit.via == :system
    end

    test "a purged lead's job stays while another lead is on it", c do
      _other =
        lead_fixture(c.fiza_scope,
          job: c.job,
          archived: true,
          archived_at: day(170),
          last_activity_at: day(170)
        )

      assert %{leads: 1, jobs: 1} = Retention.purge(day(180))
      refute is_nil(Repo.get(Data.Jobs.Job, c.job.id))
    end

    test "after the purge the guard still refuses the pair; Apply again… makes a new lead", c do
      %{leads: 1} = Retention.purge(day(180))
      job = job_fixture(c.fiza_scope, team: c.backend, url: c.job.source_url)

      assert %{answer: "refused", existing: %{purged: true, team: "this"}} =
               Guard.assess(c.fiza_scope, job.canonical_key, c.backend.id, c.golang)

      day = Words.day(c.quiet.applied_at, c.org.timezone)

      assert {:error, {:duplicate_application, %{message: message, existing: existing}}} =
               Leads.create(
                 c.fiza_scope,
                 %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "apply"},
                 day(181)
               )

      assert message ==
               "Already applied as “Golang backend” on #{day}; that lead was cleared after 180 quiet days."

      assert existing.purged

      assert {:error, :override_reason_required} =
               Leads.create(
                 c.fiza_scope,
                 %{
                   "job_id" => job.id,
                   "profile_id" => c.golang.id,
                   "as" => "apply",
                   "again_reason" => " "
                 },
                 day(181)
               )

      assert {:ok, sheet} =
               Leads.create(
                 c.fiza_scope,
                 %{
                   "job_id" => job.id,
                   "profile_id" => c.golang.id,
                   "as" => "apply",
                   "again_reason" => "The old lead was cleared; the role is open again"
                 },
                 day(181)
               )

      [first] = Store.events(sheet.id)
      assert first.kind == :applied and first.is_again
      assert first.note == "The old lead was cleared; the role is open again"

      for lead <- [c.hira, c.bilal],
          do: assert([_] = notes(lead.id, "leads.applied_again"))

      # Another profile of the same customer is warned, by the new lead and
      # by the tombstone, as a live lead does.
      other = profile_fixture(c.tanweer, title: "Elixir backend")

      assert %{answer: "warn", same_customer: same} =
               Guard.assess(c.fiza_scope, job.canonical_key, c.backend.id, other)

      assert [%{purged: true, profile: %{title: "Golang backend"}, state: nil}] =
               Enum.filter(same, &Map.get(&1, :purged))
    end
  end

  describe "the preview" do
    test "the next 14 days: nothing at 60, the lead and its job at 77; by chair", c do
      assert {:ok, %{archives: [], purges: [], jobs: []}} =
               Retention.preview(scope_for(c.dawud), %{}, day(60))

      assert {:ok, %{archives: [archive], jobs: jobs}} =
               Retention.preview(scope_for(c.hira), %{"team_id" => c.backend.id}, day(77))

      assert archive.lead.id == c.quiet.id and archive.on == ~D[2027-01-30]
      assert archive.quiet_since == @t0
      assert archive.lead.job.title == "Backend Developer"
      assert Enum.map(jobs, & &1.job.id) == [c.shared.id]

      assert {:ok, %{archives: [_]}} = Retention.preview(scope_for(c.bilal), %{}, day(77))
      assert Retention.preview(scope_for(c.fiza), %{}, day(77)) == {:error, :not_found}

      assert Retention.preview(scope_for(c.bilal), %{"team_id" => c.frontend.id}, day(77)) ==
               {:error, :not_found}

      assert Retention.preview(customer_scope_for(c.tanweer), %{}, day(77)) ==
               {:error, :not_found}

      %{leads: 1} = Retention.archive(day(90))

      assert {:ok, %{purges: [purge]}} = Retention.preview(scope_for(c.dawud), %{}, day(170))
      assert purge.on == ~D[2027-04-30] and purge.archived_at == day(90)
    end
  end

  test "run_all: the follow-up scan, then warn, archive and purge, in order", _c do
    assert [
             {"follow_up_scan", %{due: _, notified: _, events: _}},
             {"warn_sweep", %{warned: _}},
             {"archive_sweep", %{leads: _, jobs: _}},
             {"purge_sweep", %{leads: _, jobs: _}}
           ] = Retention.run_all(day(1))
  end
end
