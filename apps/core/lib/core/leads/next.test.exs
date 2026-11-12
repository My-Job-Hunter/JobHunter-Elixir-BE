defmodule Core.Leads.NextTest do
  @moduledoc """
  AQ-04B §6.1, the pure rule: the earliest due, open task first; then
  *Follow-up due*; then *No response?*; else nothing — with §11.3's words.
  """

  use ExUnit.Case, async: true

  alias Core.Leads.Next

  doctest Next

  @now ~U[2026-11-11 09:00:00.000000Z]
  @settings %{no_response_days: 14}

  defp task(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        title: "Task",
        state: :todo,
        due_at: nil,
        due_on: nil,
        archived_at: nil
      },
      Map.new(attrs)
    )
  end

  @due %{state: :due, number: 1, of: 2, count: 0, since: ~U[2026-11-09 09:00:00.000000Z]}
  @silent %{state: :no_response, number: nil, of: 2, count: 2, since: @now}

  test "the earliest due open task comes first, worded with its day" do
    cv = task(title: "Upload the updated CV", due_at: ~U[2026-11-12 10:00:00.000000Z])
    later = task(title: "Later", due_on: ~D[2026-11-20])

    assert %{kind: "task", words: "Task · Upload the updated CV · due Thu", task_id: id} =
             Next.of([later, cv], @due, @settings, @now, "Etc/UTC")

    assert id == cv.id
  end

  test "a task on a day is placed at that day's start in the zone" do
    day = task(title: "Send the portfolio link", due_on: ~D[2026-11-12])
    time = task(title: "Call back", due_at: ~U[2026-11-12 08:00:00.000000Z])

    # Karachi's 12 Nov starts at 11 Nov 19:00 UTC, before the call.
    assert %{task_id: id, at: at} = Next.of([time, day], nil, @settings, @now, "Asia/Karachi")
    assert id == day.id
    assert at == ~U[2026-11-11 19:00:00Z]
  end

  test "done, closed, archived and undated tasks never come next" do
    tasks = [
      task(state: :done, due_at: ~U[2026-11-12 10:00:00.000000Z]),
      task(state: :closed, due_at: ~U[2026-11-12 10:00:00.000000Z]),
      task(archived_at: @now, due_at: ~U[2026-11-12 10:00:00.000000Z]),
      task(title: "No due")
    ]

    assert %{kind: "follow_up"} = Next.of(tasks, @due, @settings, @now, "Etc/UTC")
  end

  test "Follow-up due, then No response?, then nothing" do
    assert %{kind: "follow_up", words: "Follow up · 1st of 2 · due since Mon", task_id: nil} =
             Next.of([], @due, @settings, @now, "Etc/UTC")

    assert %{kind: "no_response", words: "No response in 14 days"} =
             Next.of([], @silent, @settings, @now, "Etc/UTC")

    assert Next.of([], %{state: :none}, @settings, @now, "Etc/UTC") == nil
    assert Next.of([], nil, @settings, @now, "Etc/UTC") == nil
  end
end
