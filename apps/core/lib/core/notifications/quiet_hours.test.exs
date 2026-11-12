defmodule Core.Notifications.QuietHoursTest do
  use ExUnit.Case, async: true

  alias Core.Notifications.QuietHours

  doctest Core.Notifications.QuietHours

  defp quiet?(at, timezone \\ "Etc/UTC"),
    do: QuietHours.quiet?(at, ~T[22:00:00], ~T[07:00:00], timezone)

  # `deliver_after` returns the UTC instant to store; the hour it stands for
  # is the user's, so assertions have to look at it from where they are.
  defp local(at, timezone), do: DateTime.shift_zone!(at, timezone)

  describe "quiet?" do
    # 22 → 7 wraps midnight, which is the case the obvious `hour >= start and
    # hour < end` gets exactly backwards.
    test "is quiet in the evening half of a wrapping window" do
      assert quiet?(~U[2026-07-29 22:00:00Z])
      assert quiet?(~U[2026-07-29 23:59:00Z])
    end

    test "is quiet in the morning half of a wrapping window" do
      assert quiet?(~U[2026-07-29 00:00:00Z])
      assert quiet?(~U[2026-07-29 06:59:00Z])
    end

    test "is not quiet during the day" do
      refute quiet?(~U[2026-07-29 07:00:00Z])
      refute quiet?(~U[2026-07-29 12:00:00Z])
      refute quiet?(~U[2026-07-29 21:59:00Z])
    end

    test "handles a window that does not wrap" do
      assert QuietHours.quiet?(~U[2026-07-29 14:00:00Z], ~T[13:00:00], ~T[16:00:00], "Etc/UTC")
      refute QuietHours.quiet?(~U[2026-07-29 16:00:00Z], ~T[13:00:00], ~T[16:00:00], "Etc/UTC")
      refute QuietHours.quiet?(~U[2026-07-29 12:00:00Z], ~T[13:00:00], ~T[16:00:00], "Etc/UTC")
    end

    test "a window can start and end on the half hour" do
      assert QuietHours.quiet?(~U[2026-07-29 22:45:00Z], ~T[22:30:00], ~T[06:30:00], "Etc/UTC")
      refute QuietHours.quiet?(~U[2026-07-29 22:15:00Z], ~T[22:30:00], ~T[06:30:00], "Etc/UTC")
      refute QuietHours.quiet?(~U[2026-07-29 06:30:00Z], ~T[22:30:00], ~T[06:30:00], "Etc/UTC")

      at =
        QuietHours.deliver_after(~U[2026-07-29 23:00:00Z], ~T[22:30:00], ~T[06:30:00], "Etc/UTC")

      assert {at.hour, at.minute} == {6, 30}
    end

    test "an empty window is never quiet" do
      refute QuietHours.quiet?(~U[2026-07-29 09:00:00Z], ~T[09:00:00], ~T[09:00:00], "Etc/UTC")
    end

    # The hours are wall-clock hours where the user is, so the same instant is
    # quiet for one person and the middle of the afternoon for another.
    test "is judged in the user's zone" do
      at = ~U[2026-07-29 23:00:00Z]

      assert quiet?(at, "Etc/UTC")
      refute quiet?(at, "Pacific/Auckland")
    end

    test "an unknown zone is treated as not quiet — deliver rather than lose" do
      refute quiet?(~U[2026-07-29 23:00:00Z], "Mars/Olympus")
    end
  end

  describe "deliver_after" do
    test "is nil during the day — send it now" do
      assert QuietHours.deliver_after(
               ~U[2026-07-29 12:00:00Z],
               ~T[22:00:00],
               ~T[07:00:00],
               "Etc/UTC"
             ) == nil
    end

    # The whole point: quiet hours defer, they never drop. A reminder that
    # would fire at 03:00 is held until the window opens, not discarded.
    test "defers a small-hours notification to the morning" do
      at =
        QuietHours.deliver_after(~U[2026-07-29 03:00:00Z], ~T[22:00:00], ~T[07:00:00], "Etc/UTC")

      assert DateTime.to_date(at) == ~D[2026-07-29]
      assert at.hour == 7
    end

    test "defers a late-evening notification to the next morning" do
      at =
        QuietHours.deliver_after(~U[2026-07-29 23:30:00Z], ~T[22:00:00], ~T[07:00:00], "Etc/UTC")

      assert DateTime.to_date(at) == ~D[2026-07-30]
      assert at.hour == 7
    end

    test "the deferred instant is itself no longer quiet" do
      at =
        QuietHours.deliver_after(~U[2026-07-29 23:30:00Z], ~T[22:00:00], ~T[07:00:00], "Etc/UTC")

      refute QuietHours.quiet?(at, ~T[22:00:00], ~T[07:00:00], "Etc/UTC")
    end

    test "resolves the opening hour in the user's zone" do
      # Noon UTC is midnight in Auckland, so it is quiet there even though it
      # is the middle of the day here.
      at =
        QuietHours.deliver_after(
          ~U[2026-07-29 12:00:00Z],
          ~T[22:00:00],
          ~T[07:00:00],
          "Pacific/Auckland"
        )

      assert local(at, "Pacific/Auckland").hour == 7
    end

    # 2026-03-29 is when Europe/London springs forward. Adding 86,400 seconds
    # to a UTC instant is safe; asking for 07:00 local afterwards is where a
    # naive implementation drifts by an hour.
    test "lands on the right wall-clock hour across a DST change" do
      at =
        QuietHours.deliver_after(
          ~U[2026-03-28 23:30:00Z],
          ~T[22:00:00],
          ~T[07:00:00],
          "Europe/London"
        )

      london = local(at, "Europe/London")

      assert london.hour == 7
      assert DateTime.to_date(london) == ~D[2026-03-29]
    end
  end
end
