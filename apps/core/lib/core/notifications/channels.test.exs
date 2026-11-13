defmodule Core.Notifications.ChannelsTest do
  @moduledoc """
  The planning rule (AQ-08 §6, §7.1, §11.4), **as a table over every kind
  and chair**: each of the 32 kinds (AQ-09 adds two) plans exactly the ledger rows of §6 for
  each chair — staff with a browser and the extension, staff with neither, a
  customer with a browser, a customer with none — at the right moment.
  Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Core.Notifications.Channels
  alias Data.Seeds.Notifications, as: Seed

  doctest Channels

  @now ~U[2026-11-12 06:00:00Z]

  # AQ-08 §6, row by row: each kind's default channels.
  @matrix %{
    "tasks.assigned" => ~w(inapp push),
    "tasks.customer_created" => ~w(inapp push),
    "tasks.commented" => ~w(inapp push),
    "tasks.mentioned" => ~w(inapp push),
    "tasks.completed" => ~w(inapp),
    "tasks.due_soon" => ~w(inapp digest),
    "tasks.overdue" => ~w(inapp digest),
    "tasks.nudged" => ~w(inapp push),
    "leads.assigned" => ~w(inapp push),
    "leads.moved" => ~w(inapp),
    "leads.applied_again" => ~w(inapp),
    "leads.customer_update" => ~w(inapp),
    "leads.customer_milestone" => ~w(inapp push email),
    "leads.follow_up_due" => ~w(inapp digest),
    "leads.archive_warned" => ~w(inapp digest),
    "leads.archived" => ~w(inapp digest),
    "conversations.reply_received" => ~w(inapp push extension),
    "conversations.triage_new" => ~w(inapp digest),
    "conversations.forwarding_confirm" => ~w(inapp push email),
    "meetings.scheduled" => ~w(inapp push email),
    "meetings.changed" => ~w(inapp push email),
    "meetings.day_before" => ~w(inapp push email),
    "meetings.reminder" => ~w(inapp push),
    "meetings.proposed" => ~w(inapp push),
    "approvals.requested" => ~w(inapp push email),
    "approvals.decided" => ~w(inapp push email),
    "approvals.commented" => ~w(inapp push),
    "approvals.due_soon" => ~w(inapp push email),
    "approvals.overdue" => ~w(inapp push email),
    "approvals.expired" => ~w(inapp push email),
    "account.digest" => ~w(inapp email),
    "account.push_test" => ~w(inapp push)
  }

  @passing ~w(meetings.reminder account.digest account.push_test)

  # What each chair can have (§4): staff with a browser and a device, staff
  # with neither, a customer with a browser (never the extension), a
  # customer with none. Email is everyone's sign-in address.
  @chairs %{
    staff_with_both: %{push: true, email: true, extension: true},
    staff_bare: %{push: false, email: true, extension: false},
    customer_with_browser: %{push: true, email: true, extension: false},
    customer_bare: %{push: false, email: true, extension: false}
  }

  @no_window %{quiet_hours_start: nil, quiet_hours_end: nil, zone: "Asia/Karachi"}

  defp kind(key) do
    group = key |> String.split(".") |> hd()

    %{
      key: key,
      group: group,
      channels: Map.fetch!(@matrix, key),
      can_ignore_quiet_hours: key in @passing,
      can_disable: group != "account"
    }
  end

  defp plan(key, switches \\ %{}, targets, settings \\ @no_window, now \\ @now),
    do: Channels.plan(kind(key), switches, targets, settings, now)

  test "the reference seed holds §6's matrix: thirty-two kinds, three of them passing quiet hours" do
    assert Map.new(Seed.kinds()) == @matrix
    assert Enum.sort(Seed.passing_quiet_hours()) == Enum.sort(@passing)
  end

  test "every kind × every chair: exactly §6's ledger rows the chair can have, at the right moment" do
    for {key, channels} <- @matrix, {chair, targets} <- @chairs do
      expected =
        for c <- [:push, :email, :extension],
            Atom.to_string(c) in channels,
            targets[c],
            do: c

      planned = plan(key, targets)

      assert Enum.map(planned, & &1.channel) == expected, "#{key} for #{chair}"
      refute Enum.any?(planned, & &1.deferred), "#{key} for #{chair} is not held"

      for %{channel: channel, deliver_after: at} <- planned do
        wait =
          if channel == :email and not String.starts_with?(key, ~w(meetings. account.)),
            do: 600,
            else: 0

        assert DateTime.diff(at, @now) == wait, "#{key} #{channel} for #{chair}"
      end
    end
  end

  test "in-app and the digest are never ledger rows" do
    for key <- ~w(tasks.completed tasks.overdue leads.follow_up_due conversations.triage_new) do
      assert plan(key, @chairs.staff_with_both) == []
    end
  end

  test "a group switch off stops that channel; on (or no row) brings the default back" do
    both = @chairs.staff_with_both

    assert [:email] = plan("approvals.requested", %{push: false}, both) |> Enum.map(& &1.channel)
    assert [:push] = plan("approvals.requested", %{email: false}, both) |> Enum.map(& &1.channel)

    assert [:push] =
             plan("conversations.reply_received", %{extension: false}, both)
             |> Enum.map(& &1.channel)

    assert [:push, :email] =
             plan("approvals.requested", %{push: true, email: true}, both)
             |> Enum.map(& &1.channel)
  end

  test "Account can't be turned off: its switches are ignored" do
    off = %{push: false, email: false}

    assert [:email] = plan("account.digest", off, @chairs.staff_bare) |> Enum.map(& &1.channel)

    assert [:push] =
             plan("account.push_test", off, @chairs.staff_with_both) |> Enum.map(& &1.channel)
  end

  describe "quiet hours (22:00–08:00 in Karachi)" do
    @window %{
      quiet_hours_start: ~T[22:00:00],
      quiet_hours_end: ~T[08:00:00],
      zone: "Asia/Karachi"
    }
    # 23:00 in Karachi; the window ends at 08:00 there, 03:00 UTC.
    @night ~U[2026-11-12 18:00:00Z]
    @opens ~U[2026-11-13 03:00:00.000000Z]

    test "push, email and the extension wait for the window's end, marked deferred" do
      both = @chairs.staff_with_both

      assert [
               %{channel: :push, deliver_after: @opens, deferred: true},
               %{channel: :email, deliver_after: @opens, deferred: true}
             ] = plan("approvals.requested", %{}, both, @window, @night)

      assert [
               %{channel: :push, deliver_after: @opens, deferred: true},
               %{channel: :extension, deliver_after: @opens, deferred: true}
             ] = plan("conversations.reply_received", %{}, both, @window, @night)
    end

    test "the meeting reminders, the digest and the push test pass" do
      both = @chairs.staff_with_both

      for key <- @passing do
        for row <- plan(key, %{}, both, @window, @night) do
          refute row.deferred
          assert row.deliver_after == @night
        end
      end
    end

    test "outside the window nothing waits; an email that would land inside it does" do
      both = @chairs.staff_with_both
      # 21:55 in Karachi: push goes now, the email's 22:05 is inside.
      before = ~U[2026-11-12 16:55:00Z]

      assert [
               %{channel: :push, deliver_after: ^before, deferred: false},
               %{channel: :email, deliver_after: @opens, deferred: true}
             ] = plan("approvals.requested", %{}, both, @window, before)
    end
  end
end
