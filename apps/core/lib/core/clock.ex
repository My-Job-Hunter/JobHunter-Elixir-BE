defmodule Core.Clock do
  @moduledoc """
  The one *now*.

  **Rules take `now` as an argument** (PLAN §15.7: every rule takes `now`;
  every job is idempotent). A pure engine never reads the clock; the caller
  that orchestrates it asks this module once and passes the value down, so a
  test can hand a rule any moment it likes.

  ## Freezing it in a test

  `freeze/1` pins *now* for the calling process only, so `async: true` tests
  cannot see each other's clocks:

      Core.Clock.freeze(~U[2026-11-06 09:00:00.000000Z])
      Core.Clock.now()
      #=> ~U[2026-11-06 09:00:00.000000Z]

  It lives in the process dictionary, so a process the test spawns reads the
  real time. Pass `now` to it instead: that is the rule above.

  PLAN P4 moves a **dev clock** (an offset a whole dev server shares, to watch
  leads archive after 90 quiet days) into this module; nothing else may read
  the time for a rule.
  """

  @key {__MODULE__, :frozen}

  @doc "The time, in UTC: the frozen moment for this process, or the real one."
  @spec now() :: DateTime.t()
  def now do
    case Process.get(@key) do
      %DateTime{} = frozen -> frozen
      nil -> DateTime.utc_now()
    end
  end

  @doc "Today's date in UTC, read from `now/0`."
  @spec today() :: Date.t()
  def today, do: DateTime.to_date(now())

  @doc "Pins `now/0` to `at` for the calling process. Tests only."
  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{time_zone: "Etc/UTC"} = at) do
    Process.put(@key, at)
    :ok
  end

  @doc "Lets `now/0` run again for the calling process."
  @spec unfreeze() :: :ok
  def unfreeze do
    Process.delete(@key)
    :ok
  end
end
