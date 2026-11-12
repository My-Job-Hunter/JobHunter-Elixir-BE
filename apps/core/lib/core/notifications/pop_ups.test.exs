defmodule Core.Notifications.PopUpsTest do
  @moduledoc """
  The extension channel (AQ-08 §7.5, §11.4) and delivery health (§9): a
  reply raises one pop-up, claimed by the first poll and by no other; a
  held one waits for its time; a group switched off is skipped. Health is
  the system admin's, counts per channel and the latest failures.
  """

  use Core.CoreCase, async: true

  alias Core.Notifications
  alias Core.Notifications.{Health, PopUps}
  alias Data.Notifications.Deliveries

  @now ~U[2026-11-12 06:00:00.000000Z]

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    dawud = admin_fixture(org, display_name: "Dawud Kalim")
    fiza = member_fixture(team, :member, user_fixture(display_name: "Fiza"))
    device_fixture(scope_for(fiza))
    %{org: org, dawud: dawud, fiza: fiza, scope: Data.Scope.system(org)}
  end

  defp reply(c, n, at \\ @now) do
    {:ok, row} =
      Notifications.ensure(
        c.scope,
        %{
          user_id: c.fiza.id,
          notification_kind_key: "conversations.reply_received",
          title: "Mei Chen replied on “Backend Developer · Bamboo Invest”",
          body: "Thanks, we'll be in touch",
          link_path: "/leads/#{n}",
          dedupe_key: "message:#{n}"
        },
        at
      )

    row
  end

  test "claimed by the first poll, oldest first, with the console's link; a second poll gets nothing",
       c do
    first = reply(c, 1)
    second = reply(c, 2, DateTime.add(@now, 5, :second))
    later = DateTime.add(@now, 60, :second)

    assert {:ok, %{items: [one, two]}} = PopUps.claim(scope_for(c.fiza), later)
    assert one.id == first.id and two.id == second.id
    assert one.kind == "conversations.reply_received"
    assert one.body == "Thanks, we'll be in touch"
    assert one.url == "http://localhost:5800/leads/1?n=#{first.id}"

    assert {:ok, %{items: []}} = PopUps.claim(scope_for(c.fiza), later)
    assert [%{channel: :extension, state: :sent}] = Deliveries.for_notification(first.id)
  end

  test "not before it is due; a group switched off is skipped, not shown", c do
    {:ok, _} =
      Data.Accounts.put_settings(c.fiza.id, %{
        quiet_hours_start: ~T[10:00:00],
        quiet_hours_end: ~T[12:00:00]
      })

    # 11:00 in Karachi: held to 12:00 there, 07:00 UTC.
    held = reply(c, 3)
    assert {:ok, %{items: []}} = PopUps.claim(scope_for(c.fiza), @now)

    assert {:ok, %{items: [%{id: id}]}} =
             PopUps.claim(scope_for(c.fiza), ~U[2026-11-12 07:00:00.000000Z])

    assert id == held.id

    {:ok, _} =
      Data.Accounts.put_settings(c.fiza.id, %{quiet_hours_start: nil, quiet_hours_end: nil})

    off = reply(c, 4)
    preference_fixture(c.fiza, "conversations", %{extension: false})

    assert {:ok, %{items: []}} = PopUps.claim(scope_for(c.fiza), @now)

    assert [%{state: :skipped, skip_reason: :preference_off}] =
             Deliveries.for_notification(off.id)
  end

  test "health: the system admin's alone, the last day per channel and the latest failures, no body",
       c do
    push_subscription_fixture(c.fiza)
    n = reply(c, 5)
    [push, extension] = Deliveries.for_notification(n.id)
    :ok = Deliveries.mark_sent(push, @now)
    :failed = Deliveries.record_failure(extension, "mailbox unavailable", @now, @now, 1)

    assert Health.get(scope_for(c.fiza), @now) ==
             {:error, {:forbidden, "Only the system admin can see delivery health."}}

    assert {:ok, health} = Health.get(scope_for(c.dawud), DateTime.add(@now, 60, :second))
    assert health.since == DateTime.add(@now, 60 - 86_400, :second)

    assert health.channels == [
             %{channel: :push, sent: 1, waiting: 0, skipped: 0, failed: 0},
             %{channel: :email, sent: 0, waiting: 0, skipped: 0, failed: 0},
             %{channel: :extension, sent: 0, waiting: 0, skipped: 0, failed: 1}
           ]

    assert [
             %{
               kind: "conversations.reply_received",
               kind_label: "Reply received",
               channel: :extension,
               person: %{id: id, name: "Fiza"},
               error: "mailbox unavailable"
             } = failure
           ] = health.failures

    assert id == c.fiza.id
    refute Map.has_key?(failure, :body)
  end
end
