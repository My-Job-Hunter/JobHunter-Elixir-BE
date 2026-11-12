defmodule Core.RealtimeTest do
  @moduledoc "The socket's topics (AQ-02 §7.4): who joins which, and where a task's change goes."

  use Core.CoreCase, async: true

  alias Core.Realtime

  setup do: board_cast_fixture()

  test "user: that person; team: its members and the admins; customer: themselves and staff who read them",
       c do
    assert Realtime.may_join?(c.fiza.id, "user:" <> c.fiza.id)
    refute Realtime.may_join?(c.fiza.id, "user:" <> c.qasim.id)

    assert Realtime.may_join?(c.muaz.id, "team:" <> c.backend.id)
    refute Realtime.may_join?(c.muaz.id, "team:" <> c.frontend.id)
    assert Realtime.may_join?(c.dawud.id, "team:" <> c.frontend.id)
    refute Realtime.may_join?(c.tanweer.user_id, "team:" <> c.backend.id)
    refute Realtime.may_join?(c.fiza.id, "team:not-a-team")

    assert Realtime.may_join?(c.tanweer.user_id, "customer:" <> c.tanweer.id)
    refute Realtime.may_join?(c.tanweer.user_id, "customer:" <> c.naveed.id)
    assert Realtime.may_join?(c.fiza.id, "customer:" <> c.tanweer.id)
    refute Realtime.may_join?(c.bilal.id, "customer:" <> c.imran.id)
    refute Realtime.may_join?(c.fiza.id, "lead:anything")
    refute Realtime.may_join?(c.fiza.id, "nope:anything")
  end

  test "a task's events go to its teams, and to the customer only while they see it", c do
    hira = scope_for(c.hira)
    staff_only = task_fixture(hira, team: c.backend, customer: c.tanweer)
    shared = %{staff_only | customer_access: :shared}

    assert Realtime.task_events("task_updated", nil, staff_only) == [
             {"team:" <> c.backend.id, "task_updated", %{task: staff_only.id}}
           ]

    assert {"customer:" <> c.tanweer.id, "task_updated", %{task: staff_only.id}} in Realtime.task_events(
             "task_updated",
             staff_only,
             shared
           )

    assert {"customer:" <> c.tanweer.id, "task_deleted", %{task: staff_only.id}} in Realtime.task_events(
             "task_deleted",
             shared,
             staff_only
           )

    refute Enum.any?(
             Realtime.task_events("task_updated", shared, shared, customer: false),
             &match?({"customer:" <> _, _, _}, &1)
           )

    moved = %{staff_only | team_id: c.frontend.id}

    topics =
      for {topic, _event, _payload} <- Realtime.task_events("task_updated", staff_only, moved),
          do: topic

    assert Enum.sort(topics) == Enum.sort(["team:" <> c.backend.id, "team:" <> c.frontend.id])
  end

  test "lead events go to the job's team, the profile's customer and the lead's own topic, ids only",
       c do
    lead = Data.Leads.reload(lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang))

    assert Realtime.lead_events("lead_moved", lead) == [
             {"team:" <> c.backend.id, "lead_moved", %{lead: lead.id}},
             {"customer:" <> c.tanweer.id, "lead_moved", %{lead: lead.id}},
             {"lead:" <> lead.id, "event_added", %{lead: lead.id}}
           ]

    assert Realtime.lead_topic("notes_changed", lead.id) ==
             {"lead:" <> lead.id, "notes_changed", %{lead: lead.id}}

    assert_raise FunctionClauseError, fn -> Realtime.lead_events("lead_gone", lead) end
  end

  test "lead: whoever reads the lead, by peer_leads, and its customer (AQ-04B §8.3)", c do
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
    topic = "lead:" <> lead.id

    for user <- [c.fiza, c.hira, c.bilal, c.dawud], do: assert(Realtime.may_join?(user.id, topic))
    assert Realtime.may_join?(c.tanweer.user_id, topic)
    refute Realtime.may_join?(c.naveed.user_id, topic)
    refute Realtime.may_join?(c.imran.user_id, topic)

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    refute Realtime.may_join?(c.muaz.id, topic)
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})
    assert Realtime.may_join?(c.muaz.id, topic)
  end
end
