defmodule Core.Notifications.QuietHours do
  @moduledoc """
  When a person's phone must not buzz (AQ-08 §7.3; copied from mCart's).

  **Quiet hours defer; they never drop** (PLAN §11). Push, email and pop-ups
  that fall inside the window wait for its end; the bell fills at once.
  Only kinds with `can_ignore_quiet_hours` pass: the 1 h and 10 min meeting
  reminders (a night interview with a US company must not wait for
  morning, QP8-8), the digest and the push test.

  The window is the person's **local wall clock**, two `Time`s
  (`user_settings.quiet_hours_start` to `quiet_hours_end`), judged in their
  zone (`persons.timezone`): 22:00 means ten at night where they are, not in
  UTC. Windows normally wrap midnight, the case a comparison gets wrong if
  written the obvious way. **Pure**: it takes the moment and answers one.
  """

  @doc """
  Is this instant inside the window?

      iex> Core.Notifications.QuietHours.quiet?(~U[2026-07-29 23:30:00Z], ~T[22:00:00], ~T[07:00:00], "Etc/UTC")
      true

      iex> Core.Notifications.QuietHours.quiet?(~U[2026-07-29 12:00:00Z], ~T[22:00:00], ~T[07:00:00], "Etc/UTC")
      false
  """
  @spec quiet?(DateTime.t(), Time.t(), Time.t(), String.t()) :: boolean()
  def quiet?(%DateTime{} = at, %Time{} = from, %Time{} = until, timezone) do
    case local_time(at, timezone) do
      nil -> false
      time -> in_window?(time, from, until)
    end
  end

  @doc """
  When this may be delivered, or `nil` if `at` is fine.

  Answers the **UTC instant** at which the window next ends, which is what
  goes in `notification_deliveries.deliver_after`. The hour it stands for is
  local.
  """
  @spec deliver_after(DateTime.t(), Time.t(), Time.t(), String.t()) :: DateTime.t() | nil
  def deliver_after(%DateTime{} = at, %Time{} = from, %Time{} = until, timezone) do
    if quiet?(at, from, until, timezone) do
      next_open(at, until, timezone)
    end
  end

  # A window that wraps midnight (22:00 → 07:00) is the normal case, and the
  # naive `time >= from and time < until` gets it exactly backwards.
  defp in_window?(time, from, until) do
    case Time.compare(from, until) do
      :eq -> false
      :lt -> not before?(time, from) and before?(time, until)
      :gt -> not before?(time, from) or before?(time, until)
    end
  end

  defp before?(a, b), do: Time.compare(a, b) == :lt

  # The UTC instant to store, resolved from a local wall-clock time.
  defp next_open(at, until, timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} ->
        today = DateTime.to_date(local)

        # Before the end means later today; at or after it means the window
        # started this evening and opens tomorrow morning.
        #
        # **`Date.add/2`, never `+ 86_400`.** "Tomorrow at 7am" is calendar
        # arithmetic: the day the clocks change is 23 or 25 hours long, and
        # adding a fixed number of seconds lands an hour out.
        date = if before?(DateTime.to_time(local), until), do: today, else: Date.add(today, 1)

        at_local(date, until, timezone)

      _unknown_zone ->
        nil
    end
  end

  defp at_local(date, time, zone) do
    {:ok, naive} = NaiveDateTime.new(date, %{time | microsecond: {0, 6}})

    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      _error -> nil
    end
  end

  defp local_time(at, timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} -> DateTime.to_time(local)
      _unknown_zone -> nil
    end
  end
end
