defmodule Core.Leads.FollowUpTest do
  @moduledoc """
  AQ-04B §6.2 done: *Log follow-up* (a person's, customer-visible event, so
  activity; refused off an Applied/Seen stage and past the last one) and the
  hourly scan (one `follow_up_due` and one bell per follow-up owed; run
  twice, nothing more), with the sheet's badge and *Next*.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Leads
  alias Core.Leads.{Act, FollowUp}
  alias Data.Leads, as: Store

  @t0 ~U[2026-11-02 09:00:00.000000Z]

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")

    {:ok, sheet} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "apply"},
        @t0
      )

    Map.put(c, :sheet, sheet)
  end

  defp from(sheet), do: %{"state" => "in_progress", "stage" => sheet.stage.key}

  test "+3 days: due, the owner's bell once, Next says the 1st of 2; logged, then the 2nd", c do
    assert FollowUp.scan(day(2)) == %{due: 0, notified: 0, events: 0}
    assert FollowUp.scan(day(3)) == %{due: 1, notified: 1, events: 1}
    assert FollowUp.scan(day(3)) == %{due: 1, notified: 0, events: 0}

    {:ok, sheet} = Leads.get(scope_for(c.fiza), c.sheet.id, day(3))
    assert sheet.follow_up == %{state: :due, count: 0, of: 2}
    assert sheet.next.kind == "follow_up"
    assert sheet.next.words =~ "Follow up · 1st of 2 · due since"

    assert {:ok, logged} =
             FollowUp.log(
               scope_for(c.fiza),
               c.sheet.id,
               %{"from" => from(c.sheet), "note" => "A short nudge"},
               day(3)
             )

    assert logged.follow_up == %{state: :none, count: 1, of: 2}
    [event | _] = Store.events(c.sheet.id)
    assert event.kind == :follow_up_logged and event.visibility == :customer
    assert event.to_label == "1 of 2" and event.note == "A short nudge"
    assert Store.reload(Store.get(c.org.id, c.sheet.id)).last_activity_at == day(3)

    assert %{notified: 1, events: 1} = FollowUp.scan(day(6))
    {:ok, sheet} = Leads.get(scope_for(c.fiza), c.sheet.id, day(6))
    assert sheet.next.words =~ "Follow up · 2nd of 2"

    rows =
      Repo.all(
        from(n in Data.Notifications.Notification,
          where: n.notification_kind_key == "leads.follow_up_due"
        )
      )

    assert Enum.map(rows, & &1.dedupe_key) |> Enum.sort() ==
             Enum.sort(["lead:#{c.sheet.id}:follow_up:1", "lead:#{c.sheet.id}:follow_up:2"])
  end

  test "+14 days: No response?, and Mark No response finishes it; a move clears the badge", c do
    {:ok, sheet} = Leads.get(scope_for(c.fiza), c.sheet.id, day(14))
    assert sheet.follow_up.state == :no_response

    assert sheet.next == %{
             kind: "no_response",
             words: "No response in 14 days",
             at: day(14),
             task_id: nil,
             meeting_id: nil,
             approval_id: nil
           }

    {:ok, done} =
      Act.run(
        scope_for(c.fiza),
        :finish,
        c.sheet.id,
        %{"from" => from(c.sheet), "outcome" => "no_response"},
        day(14)
      )

    assert done.outcome == :no_response and done.follow_up.state == :none
  end

  test "a lead moved past Applied clears its badge", c do
    {:ok, moved} =
      Act.run(
        scope_for(c.fiza),
        :move,
        c.sheet.id,
        %{"from" => from(c.sheet), "state" => "in_progress", "stage" => "recruiter_screen"},
        day(1)
      )

    assert moved.follow_up.state == :none
    assert FollowUp.scan(day(10)) == %{due: 0, notified: 0, events: 0}
  end

  test "refused off an Applied stage, past the last follow-up, stale, or at view", c do
    fiza = scope_for(c.fiza)
    {:ok, _} = FollowUp.log(fiza, c.sheet.id, %{"from" => from(c.sheet)}, day(3))
    {:ok, _} = FollowUp.log(fiza, c.sheet.id, %{"from" => from(c.sheet)}, day(6))

    assert FollowUp.log(fiza, c.sheet.id, %{"from" => from(c.sheet)}, day(9)) ==
             {:error, {:invalid, %{"from" => ["has all 2 follow-ups logged"]}}}

    assert {:error, {:lead_moved, _}} =
             FollowUp.log(fiza, c.sheet.id, %{"from" => %{"state" => "todo"}}, day(9))

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    assert FollowUp.log(scope_for(c.muaz), c.sheet.id, %{"from" => from(c.sheet)}, day(9)) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    {:ok, held} =
      Act.run(
        fiza,
        :hold,
        c.sheet.id,
        %{"from" => from(c.sheet), "hold_reason" => "Waiting"},
        day(9)
      )

    assert FollowUp.log(
             fiza,
             held.id,
             %{"from" => %{"state" => "on_hold", "stage" => held.stage.key}},
             day(9)
           ) ==
             {:error,
              {:invalid,
               %{"state" => ["can't log a follow-up on a lead that is On hold · Applied"]}}}
  end
end
