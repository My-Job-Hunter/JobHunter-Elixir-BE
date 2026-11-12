defmodule Utils.Clock do
  @moduledoc """
  The one *now*, for every app (AQ-08 QP8-22).

  `Core.Clock` delegates here with the same API, so `notifire`, which may not
  call `core`, reads the same time: the delivery sweep compares
  `deliver_after` with *now*, which must agree with the dev clock a run
  moves.

  **Rules take `now` as an argument** (PLAN §15.7). A pure engine never reads
  the clock; the caller that orchestrates it asks once and passes the value
  down.

  ## Freezing it in a test

  `freeze/1` pins *now* for the calling process only, so `async: true` tests
  cannot see each other's clocks. It lives in the process dictionary, so a
  process the test spawns reads the real time: pass `now` to it instead.

  ## The dev clock (AQ-04B §7.6, QP4b-1)

  A dev server shares **an offset in days** that every reader of `now/0`
  adds, kept in `:persistent_term` so it is one value for the whole VM.
  `POST /dev/clock {days}` sets it. **`freeze/1` still wins.**

  `set_offset_days/1` refuses unless `config :core, dev_clock: true` (where
  the setting has always lived; `config/dev.exs` alone sets it), so outside a
  dev server the offset is always 0.
  """

  @key {__MODULE__, :frozen}
  @offset {__MODULE__, :offset_seconds}
  @day 86_400

  @doc "The time, in UTC: the frozen moment for this process, or the real one plus the dev offset."
  @spec now() :: DateTime.t()
  def now do
    case Process.get(@key) do
      %DateTime{} = frozen -> frozen
      nil -> DateTime.add(DateTime.utc_now(), offset_seconds(), :second)
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

  @doc "The dev clock's offset, in whole days (0 unless a dev server moved it)."
  @spec offset_days() :: integer()
  def offset_days, do: div(offset_seconds(), @day)

  @doc """
  Moves the dev clock to `days` ahead of the real time (`0` resets it).
  `{:error, :disabled}` unless `config :core, dev_clock: true`.
  """
  @spec set_offset_days(integer()) :: :ok | {:error, :disabled}
  def set_offset_days(days) when is_integer(days) do
    if Application.get_env(:core, :dev_clock, false) do
      if days == 0,
        do: :persistent_term.erase(@offset),
        else: :persistent_term.put(@offset, days * @day)

      :ok
    else
      {:error, :disabled}
    end
  end

  defp offset_seconds, do: :persistent_term.get(@offset, 0)
end
