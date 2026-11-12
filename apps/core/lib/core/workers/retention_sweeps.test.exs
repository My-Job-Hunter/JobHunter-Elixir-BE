defmodule Core.Workers.RetentionSweepsTest do
  @moduledoc """
  The four hourly workers of AQ-04B (§6.2, §7.3), each **run twice** with
  the clock frozen: the second run writes nothing. They hold no rule; the
  rules are `Core.Retention.Policy` and `Core.Leads.FollowUps`, tested on
  their own.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Clock
  alias Core.Workers.{LeadFollowUpScan, RetentionArchiveSweep, RetentionPurgeSweep}
  alias Core.Workers.RetentionWarnSweep
  alias Data.Leads, as: Store

  @t0 ~U[2026-11-01 09:00:00.000000Z]

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  setup do
    on_exit(&Clock.unfreeze/0)
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend)

    Repo.update_all(from(j in Data.Jobs.Job, where: j.id == ^job.id),
      set: [last_activity_at: @t0, first_seen_at: @t0]
    )

    lead =
      lead_fixture(fiza,
        job: job,
        profile: c.golang,
        as: :apply,
        applied_at: @t0,
        last_activity_at: @t0
      )

    Map.merge(c, %{lead: lead, job: job})
  end

  defp twice(worker) do
    assert worker.perform(%Oban.Job{}) == :ok
    first = kinds()
    assert worker.perform(%Oban.Job{}) == :ok
    assert kinds() == first
    first
  end

  defp kinds do
    Repo.all(
      from(e in Data.Leads.Event, order_by: [asc: e.recorded_at, asc: e.id], select: e.kind)
    ) ++
      Repo.all(
        from(n in Data.Notifications.Notification,
          order_by: n.notification_kind_key,
          select: n.notification_kind_key
        )
      )
  end

  test "the follow-up scan: one follow_up_due and one bell, run twice", c do
    _ = Store.add_event(applied(c.lead))
    Clock.freeze(day(3))

    assert twice(LeadFollowUpScan) == [:applied, :follow_up_due, "leads.follow_up_due"]
  end

  test "the warn sweep, run twice", _c do
    Clock.freeze(day(83))
    assert twice(RetentionWarnSweep) == [:archive_warned, "leads.archive_warned"]
  end

  test "the archive sweep, run twice", c do
    Clock.freeze(day(90))
    assert twice(RetentionArchiveSweep) == [:archived, "leads.archived"]
    refute is_nil(Store.reload(c.lead).archived_at)
  end

  test "the purge sweep, run twice", c do
    Clock.freeze(day(90))
    :ok = RetentionArchiveSweep.perform(%Oban.Job{})
    Clock.freeze(day(180))

    assert twice(RetentionPurgeSweep) == []
    assert Repo.get(Data.Leads.Lead, c.lead.id) == nil
    assert Repo.get(Data.Jobs.Job, c.job.id) == nil
    assert [_print] = Repo.all(Data.Leads.Fingerprint)
  end

  defp applied(lead) do
    %{
      organisation_id: lead.organisation_id,
      lead_id: lead.id,
      kind: :applied,
      occurred_at: @t0,
      recorded_at: @t0,
      actor_kind: :user,
      actor_user_id: lead.owner_user_id,
      visibility: :customer,
      to_label: "Applied"
    }
  end
end
