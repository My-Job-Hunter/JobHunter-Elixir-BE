defmodule Core.ClockTest do
  use ExUnit.Case, async: true

  alias Core.Clock

  setup do
    on_exit(&Clock.unfreeze/0)
  end

  test "reads the real time, in UTC, when nothing is frozen" do
    before = DateTime.utc_now()
    now = Clock.now()

    assert now.time_zone == "Etc/UTC"
    assert DateTime.compare(now, before) in [:eq, :gt]
    assert DateTime.diff(now, before, :second) < 5
  end

  test "a frozen clock answers the same moment every time" do
    at = ~U[2026-11-06 09:00:00.000000Z]

    assert Clock.freeze(at) == :ok
    assert Clock.now() == at
    assert Clock.now() == at
    assert Clock.today() == ~D[2026-11-06]
  end

  test "unfreezing lets it run again" do
    Clock.freeze(~U[2001-01-01 00:00:00.000000Z])
    Clock.unfreeze()

    assert Clock.now().year >= 2026
  end

  test "a frozen clock is this process's alone" do
    Clock.freeze(~U[2001-01-01 00:00:00.000000Z])

    other = Task.async(fn -> Clock.now() end) |> Task.await()

    assert other.year >= 2026
    assert Clock.now().year == 2001
  end

  test "refuses a moment that is not in UTC" do
    shifted = DateTime.shift_zone!(~U[2026-11-06 09:00:00Z], "Asia/Karachi")

    assert_raise FunctionClauseError, fn -> Clock.freeze(shifted) end
  end
end
