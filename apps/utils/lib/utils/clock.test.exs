defmodule Utils.ClockTest do
  @moduledoc """
  The one *now* (AQ-08 QP8-22). `Core.ClockTest` exercises the whole API
  through `Core.Clock`'s delegates, the dev offset included; here, only
  what `utils` holds on its own.
  """

  use ExUnit.Case, async: true

  alias Utils.Clock

  setup do
    on_exit(&Clock.unfreeze/0)
  end

  test "frozen for this process alone; unfrozen it runs again" do
    Clock.freeze(~U[2026-11-12 22:30:00.000000Z])

    assert Clock.now() == ~U[2026-11-12 22:30:00.000000Z]
    assert Clock.today() == ~D[2026-11-12]
    assert (Task.async(&Clock.now/0) |> Task.await()).year >= 2026

    Clock.unfreeze()
    assert DateTime.diff(Clock.now(), DateTime.utc_now(), :second) < 5
  end
end
