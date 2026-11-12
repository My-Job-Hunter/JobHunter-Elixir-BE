defmodule Core.Approvals.RemindersTest do
  @moduledoc """
  Due and auto-approve (AQ-07 §9, QP7-12…14; §13 steps 4 and 5): jobs
  planned on submit, keyed by `(approval, kind, due_at)` and `(approval,
  auto_approve_at)`; `due_soon` to the open slots' people, `overdue` to
  them and the requester, once each (a job run twice tells nobody twice);
  a stale job does nothing; the expiry sweep, run twice; auto-approve
  approves with its note and runs the effect; the dev clock's catch-up;
  a revision re-plans.
  """

  use Core.CoreCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Core.Approvals
  alias Core.Approvals.{Act, Reminders}
  alias Core.Workers.{ApprovalAutoApprove, ApprovalExpirySweep, ApprovalReminder}
  alias Data.Notifications.Notification

  @now ~U[2026-11-12 09:00:00.000000Z]
  @due ~U[2026-11-16 17:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)

    policy_fixture(c.tanweer,
      approval_kind: :rate,
      needs: :customer,
      rule: :any,
      auto_approve_hours: 24
    )

    {:ok, a} =
      Approvals.draft(
        fiza,
        %{
          team_id: c.backend.id,
          lead_id: lead.id,
          approval_kind: "rate",
          title: "Rate for Bamboo",
          proposed: %{
            expectation_minor: 7_000_000,
            expectation_currency: "USD",
            expectation_period: "year"
          },
          due_at: DateTime.to_iso8601(@due),
          submit: true
        },
        @now
      )

    Map.merge(c, %{
      fiza_s: fiza,
      lead: lead,
      approval: a,
      tanweer_user: Data.Accounts.get_user(c.tanweer.user_id)
    })
  end

  defp told(kind) do
    for n <- Repo.all(Data.Notifications.Notification),
        n.notification_kind_key == kind,
        do: {n.user_id, n.dedupe_key}
  end

  test "planned on submit: due_soon, overdue and auto-approve, on the scheduling queue", c do
    reminders = all_enqueued(worker: ApprovalReminder)

    assert Enum.map(Enum.sort_by(reminders, & &1.scheduled_at, DateTime), & &1.args["kind"]) ==
             ~w(due_soon overdue)

    assert Enum.map(Enum.sort_by(reminders, & &1.scheduled_at, DateTime), & &1.scheduled_at) ==
             [~U[2026-11-15 17:00:00.000000Z], @due]

    assert [auto] = all_enqueued(worker: ApprovalAutoApprove)
    assert auto.scheduled_at == ~U[2026-11-13 09:00:00.000000Z]
    assert auto.args["approval_id"] == c.approval.id

    # Planning again plans nothing new (unique while incomplete).
    :ok = Reminders.plan(Data.Approvals.get_for_system(c.approval.id), @now)
    assert length(all_enqueued(worker: ApprovalReminder)) == 2
  end

  test "−24 h to the open slot's people, at the time the requester too; twice is still once", c do
    id = c.approval.id
    due = DateTime.to_iso8601(@due)
    args = &%{"approval_id" => id, "kind" => &1, "due_at" => due}

    # Too early: nothing.
    assert Reminders.remind(id, "due_soon", due, @now) == :early

    # The worker hands the clock (now, before the window) to the rule: nothing yet.
    assert :ok = perform_job(ApprovalReminder, args.("due_soon"))
    assert told("approvals.due_soon") == []

    assert Reminders.remind(id, "due_soon", due, ~U[2026-11-15 18:00:00.000000Z]) == :sent
    assert Reminders.remind(id, "due_soon", due, ~U[2026-11-15 18:00:00.000000Z]) == :sent
    assert told("approvals.due_soon") == [{c.tanweer_user.id, "approval:#{id}:due_soon:#{due}"}]

    # A late due_soon after the due time says nothing; overdue speaks, to the requester too.
    assert Reminders.remind(id, "due_soon", due, ~U[2026-11-16 17:30:00.000000Z]) == :stale
    assert Reminders.remind(id, "overdue", due, ~U[2026-11-16 17:30:00.000000Z]) == :sent
    assert Reminders.remind(id, "overdue", due, ~U[2026-11-16 17:30:00.000000Z]) == :sent

    assert Enum.sort(told("approvals.overdue")) ==
             Enum.sort([
               {c.tanweer_user.id, "approval:#{id}:overdue:#{due}"},
               {c.fiza.id, "approval:#{id}:overdue:#{due}"}
             ])

    [n | _] =
      Repo.all(Notification) |> Enum.filter(&(&1.notification_kind_key == "approvals.overdue"))

    assert n.title == "Overdue: Rate for Bamboo" and n.approval_id == id and
             is_nil(n.actor_user_id)

    links =
      for x <- Repo.all(Notification),
          x.notification_kind_key == "approvals.overdue",
          into: %{},
          do: {x.user_id, x.link_path}

    assert links[c.tanweer_user.id] == "/approvals/#{id}"
    assert links[c.fiza.id] == "/approvals/#{id}?team=#{c.backend.id}"

    # Decided: the job finds it moved.
    {:ok, _} =
      Act.decide(customer_scope_for(c.tanweer), id, %{decision: "approved", version: 1}, @now)

    assert Reminders.remind(id, "overdue", due, ~U[2026-11-16 17:30:00.000000Z]) == :moved
    assert all_enqueued(worker: ApprovalReminder) == []
  end

  test "expiry: three days past due with no outcome; the sweep run twice expires once", c do
    id = c.approval.id
    # Keep auto-approve out of it.
    {:ok, _} = Data.Approvals.update(Data.Approvals.get_for_system(id), %{auto_approve_at: nil})

    assert Act.expire(~U[2026-11-19 16:59:00.000000Z]) == %{expired: 0}
    assert Act.expire(~U[2026-11-19 17:00:00.000000Z]) == %{expired: 1}
    assert Act.expire(~U[2026-11-19 17:00:00.000000Z]) == %{expired: 0}
    assert :ok = perform_job(ApprovalExpirySweep, %{})

    assert %{state: :expired} = Data.Approvals.get_for_system(id)
    assert told("approvals.expired") == [{c.fiza.id, "approval:#{id}:expired"}]

    # An approval with no due date never expires.
    {:ok, undated} =
      Approvals.draft(
        c.fiza_s,
        %{
          team_id: c.backend.id,
          lead_id: c.lead.id,
          approval_kind: "asset",
          title: "x",
          slots: [%{slot: "team_lead"}],
          submit: true
        },
        @now
      )

    assert Act.expire(~U[2027-11-19 17:00:00.000000Z]) == %{expired: 0}
    assert %{state: :pending} = Data.Approvals.get_for_system(undated.id)
  end

  test "auto-approve: approved by the system after 24 hours, the effect runs; a stale job does nothing",
       c do
    id = c.approval.id
    at = DateTime.to_iso8601(~U[2026-11-13 09:00:00.000000Z])

    assert Act.auto_approve(id, ~U[2026-11-13 09:00:00.000000Z], @now) == :early

    assert Act.auto_approve(id, ~U[2026-11-14 09:00:00.000000Z], ~U[2026-11-14 09:00:00.000000Z]) ==
             :moved

    Core.Clock.freeze(~U[2026-11-13 09:00:01.000000Z])
    on_exit(&Core.Clock.unfreeze/0)
    assert :ok = perform_job(ApprovalAutoApprove, %{"approval_id" => id, "auto_approve_at" => at})
    assert :ok = perform_job(ApprovalAutoApprove, %{"approval_id" => id, "auto_approve_at" => at})

    a = Data.Approvals.get_for_system(id)
    assert %{state: :approved, effect: :applied} = a

    assert [
             %{
               decision: :approved,
               note: "Approved automatically after 24 hours.",
               decided_by_user_id: nil
             }
           ] = a.decisions

    assert Data.Leads.reload(c.lead).expectation_minor == 7_000_000

    assert [%{actor_kind: :system, to_label: "Approved"}] =
             c.lead.id |> Data.Leads.events() |> Enum.filter(&(&1.kind == :approval_decided))

    assert [{fiza_id, _key}] =
             told("approvals.decided") |> Enum.filter(&(elem(&1, 0) == c.fiza.id))

    assert fiza_id == c.fiza.id
  end

  test "the dev clock's catch-up: the nearest reminder due, then auto-approve whose time has come",
       c do
    assert Reminders.catch_up(@now) == %{reminded: 0, approved: 0}
    assert Reminders.catch_up(~U[2026-11-13 10:00:00.000000Z]) == %{reminded: 0, approved: 1}
    assert %{state: :approved} = Data.Approvals.get_for_system(c.approval.id)
  end

  test "a revision drops the old jobs and plans its own; auto-approve counts from the revision",
       c do
    id = c.approval.id

    {:ok, _} =
      Act.decide(
        customer_scope_for(c.tanweer),
        id,
        %{decision: "changes_requested", note: "Lower.", version: 1},
        @now
      )

    assert all_enqueued(worker: ApprovalAutoApprove) == []

    later = ~U[2026-11-14 09:00:00.000000Z]
    {:ok, a} = Act.revise(c.fiza_s, id, %{body_md: "Lower now."}, later)
    assert a.version == 2
    assert [auto] = all_enqueued(worker: ApprovalAutoApprove)
    assert auto.scheduled_at == ~U[2026-11-15 09:00:00.000000Z]
    assert length(all_enqueued(worker: ApprovalReminder)) == 2
  end
end
