defmodule Core.Leads.FollowUpsTest do
  @moduledoc """
  AQ-04B §6.2, the pure rule: *Follow-up due* after the gap, at most the
  settings' number; *No response?* after fourteen days with none left or the
  gap passed; a move past Applied/Seen clears both; a custom stage counts as
  its anchor; an apply-again starts the count again.
  """

  use ExUnit.Case, async: true

  alias Core.Leads.FollowUps

  @settings %{follow_up_gap_days: 3, max_follow_ups: 2, no_response_days: 14}
  @applied ~U[2026-11-01 09:00:00.000000Z]

  defp lead(attrs \\ %{}) do
    Map.merge(
      %{
        state: :in_progress,
        archived_at: nil,
        applied_at: @applied,
        stage: %{kind: :applied, anchor_kind: nil}
      },
      Map.new(attrs)
    )
  end

  defp at(days, hours \\ 0), do: DateTime.add(@applied, days * 86_400 + hours * 3600, :second)
  defp ev(kind, at), do: %{kind: kind, occurred_at: at}
  defp applied, do: ev(:applied, @applied)

  test "nothing before the gap; due from the gap, the 1st of 2" do
    assert %{state: :none, count: 0, of: 2} =
             FollowUps.assess(lead(), [applied()], @settings, at(2, 23))

    assert %{state: :due, count: 0, number: 1, since: since} =
             FollowUps.assess(lead(), [applied()], @settings, at(3))

    assert since == at(3)
  end

  test "a logged follow-up restarts the gap and counts; the 2nd falls due three days later" do
    events = [applied(), ev(:follow_up_logged, at(3))]

    assert %{state: :none, count: 1} = FollowUps.assess(lead(), events, @settings, at(5))

    assert %{state: :due, count: 1, number: 2, since: since} =
             FollowUps.assess(lead(), events, @settings, at(6))

    assert since == at(6)
  end

  # AQ-06 QP6-12: an inbound message is a response.
  test "an inbound message since the application clears both; one before it does not" do
    assert %{state: :none} =
             FollowUps.assess(lead(), [applied(), ev(:message_in, at(2))], @settings, at(20))

    assert %{state: :no_response} =
             FollowUps.assess(lead(), [applied(), ev(:message_in, at(-1))], @settings, at(20))
  end

  test "with both logged, nothing is due; at fourteen days, No response?" do
    events = [applied(), ev(:follow_up_logged, at(3)), ev(:follow_up_logged, at(6))]

    assert %{state: :none, count: 2} = FollowUps.assess(lead(), events, @settings, at(13))
    assert %{state: :no_response, count: 2} = FollowUps.assess(lead(), events, @settings, at(14))
  end

  test "no follow-up logged at all: fourteen days on, No response? wins over the one owed" do
    assert %{state: :no_response} = FollowUps.assess(lead(), [applied()], @settings, at(14))
  end

  test "a follow-up logged on day 13 holds No response? off until its gap has passed" do
    events = [applied(), ev(:follow_up_logged, at(13))]

    assert %{state: :none, count: 1} = FollowUps.assess(lead(), events, @settings, at(14))
    assert %{state: :no_response} = FollowUps.assess(lead(), events, @settings, at(16))
  end

  test "a Seen stage waits too, and a custom stage counts as its anchor" do
    seen = lead(stage: %{kind: :seen, anchor_kind: nil})
    custom = lead(stage: %{kind: :custom, anchor_kind: :applied})

    assert %{state: :due} = FollowUps.assess(seen, [applied()], @settings, at(3))
    assert %{state: :due} = FollowUps.assess(custom, [applied()], @settings, at(3))
  end

  test "a response clears both: a stage past Applied, another state, an archived lead" do
    for l <- [
          lead(stage: %{kind: :screening, anchor_kind: nil}),
          lead(state: :on_hold),
          lead(state: :done),
          lead(archived_at: at(1))
        ] do
      assert %{state: :none} = FollowUps.assess(l, [applied()], @settings, at(20))
    end
  end

  test "an apply-again starts the count again from the new applied" do
    again = at(10)

    events = [
      applied(),
      ev(:follow_up_logged, at(3)),
      ev(:follow_up_logged, at(6)),
      ev(:applied, again)
    ]

    l = lead(applied_at: again)

    assert %{state: :none, count: 0} = FollowUps.assess(l, events, @settings, at(12))
    assert %{state: :due, number: 1} = FollowUps.assess(l, events, @settings, at(13))
  end

  test "the settings decide the numbers" do
    settings = %{follow_up_gap_days: 1, max_follow_ups: 1, no_response_days: 5}
    events = [applied(), ev(:follow_up_logged, at(1))]

    assert %{state: :due} = FollowUps.assess(lead(), [applied()], settings, at(1))
    assert %{state: :none, of: 1} = FollowUps.assess(lead(), events, settings, at(2))
    assert %{state: :no_response} = FollowUps.assess(lead(), events, settings, at(5))
  end
end
