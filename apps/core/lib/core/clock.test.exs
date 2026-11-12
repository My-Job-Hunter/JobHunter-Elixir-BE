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

  # AQ-08 QP8-22: `notifire` reads `Utils.Clock`, so the two must agree.
  test "is Utils.Clock: a moment frozen through one is read through the other" do
    Clock.freeze(~U[2026-11-12 22:30:00.000000Z])

    assert Utils.Clock.now() == ~U[2026-11-12 22:30:00.000000Z]
  end

  test "refuses a moment that is not in UTC" do
    shifted = DateTime.shift_zone!(~U[2026-11-06 09:00:00Z], "Asia/Karachi")

    assert_raise FunctionClauseError, fn -> Clock.freeze(shifted) end
  end
end

defmodule Core.ClockOffsetTest do
  @moduledoc """
  The dev clock (AQ-04B §7.6): an offset every reader shares. Not async —
  the offset is the whole VM's — and always reset to 0 on the way out.
  """

  use ExUnit.Case, async: false

  alias Core.Clock

  setup do
    previous = Application.get_env(:core, :dev_clock)

    on_exit(fn ->
      Application.put_env(:core, :dev_clock, true)
      Clock.set_offset_days(0)
      Application.put_env(:core, :dev_clock, previous)
      Clock.unfreeze()
    end)
  end

  test "outside a dev server the offset cannot be set, and is 0" do
    Application.put_env(:core, :dev_clock, false)

    assert Clock.set_offset_days(92) == {:error, :disabled}
    assert Clock.offset_days() == 0
    assert DateTime.diff(Clock.now(), DateTime.utc_now(), :second) < 5
  end

  test "on a dev server it moves now for every reader, and 0 resets it" do
    Application.put_env(:core, :dev_clock, true)

    assert Clock.set_offset_days(92) == :ok
    assert Clock.offset_days() == 92

    other = Task.async(fn -> Clock.now() end) |> Task.await()
    ahead = DateTime.diff(other, DateTime.utc_now(), :day)
    assert ahead in [91, 92]

    assert Clock.set_offset_days(0) == :ok
    assert Clock.offset_days() == 0
    assert DateTime.diff(Clock.now(), DateTime.utc_now(), :second) < 5
  end

  test "a frozen clock still wins over the offset" do
    Application.put_env(:core, :dev_clock, true)
    Clock.set_offset_days(30)
    Clock.freeze(~U[2026-11-06 09:00:00.000000Z])

    assert Clock.now() == ~U[2026-11-06 09:00:00.000000Z]
  end
end
