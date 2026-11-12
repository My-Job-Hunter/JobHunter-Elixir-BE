defmodule Core.Clock do
  @moduledoc """
  The one *now*, as `core` asks for it: **a delegate to `Utils.Clock`**
  (AQ-08 QP8-22), which holds *now*, `today`, `freeze` and the dev offset
  so `notifire` reads the same time without calling `core`.

  **Rules take `now` as an argument** (PLAN §15.7: every rule takes `now`;
  every job is idempotent). A pure engine never reads the clock; the caller
  that orchestrates it asks this module once and passes the value down, so a
  test can hand a rule any moment it likes.

  `freeze/1` pins *now* for the calling process only (`async: true` tests
  cannot see each other's clocks). The dev clock (AQ-04B §7.6) is an offset
  in days every reader adds, set by `POST /dev/clock {days}` on a dev
  server and refused unless `config :core, dev_clock: true`. `freeze/1`
  still wins.
  """

  @doc "The time, in UTC: the frozen moment for this process, or the real one plus the dev offset."
  @spec now() :: DateTime.t()
  defdelegate now(), to: Utils.Clock

  @doc "Today's date in UTC, read from `now/0`."
  @spec today() :: Date.t()
  defdelegate today(), to: Utils.Clock

  @doc "Pins `now/0` to `at` for the calling process. Tests only."
  @spec freeze(DateTime.t()) :: :ok
  defdelegate freeze(at), to: Utils.Clock

  @doc "Lets `now/0` run again for the calling process."
  @spec unfreeze() :: :ok
  defdelegate unfreeze(), to: Utils.Clock

  @doc "The dev clock's offset, in whole days (0 unless a dev server moved it)."
  @spec offset_days() :: integer()
  defdelegate offset_days(), to: Utils.Clock

  @doc """
  Moves the dev clock to `days` ahead of the real time (`0` resets it).
  `{:error, :disabled}` unless `config :core, dev_clock: true`.
  """
  @spec set_offset_days(integer()) :: :ok | {:error, :disabled}
  defdelegate set_offset_days(days), to: Utils.Clock
end
