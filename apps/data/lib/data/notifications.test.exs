defmodule Data.NotificationsTest do
  @moduledoc "`ensure/2` (AQ-02 §5.2): one row per `(user_id, dedupe_key)`, however often it is asked."

  use Data.DataCase, async: true

  alias Data.Notifications
  alias Data.Notifications.Deliveries
  alias Data.Notifications.Notification
  alias Data.Scope

  setup do
    org = organisation_fixture()
    %{org: org, user: user_fixture(), scope: Scope.system(org)}
  end

  defp attrs(user, key),
    do: %{
      user_id: user.id,
      notification_kind_key: "tasks.assigned",
      title: "Hira gave you a task",
      dedupe_key: key
    }

  test "ensured twice is one row: the second answers the first and inserts nothing", %{
    scope: scope,
    user: user
  } do
    assert {:ok, %Notification{is_new: true} = first} =
             Notifications.ensure(scope, attrs(user, "task:1:assigned:g"))

    assert {:ok, %Notification{is_new: false} = second} =
             Notifications.ensure(scope, %{
               attrs(user, "task:1:assigned:g")
               | title: "Different words"
             })

    assert second.id == first.id
    assert second.title == "Hira gave you a task"
    assert Repo.aggregate(Notification, :count) == 1

    # The same key for somebody else is their own row.
    assert {:ok, %{is_new: true}} =
             Notifications.ensure(scope, attrs(user_fixture(), "task:1:assigned:g"))
  end

  test "an ensure inside a transaction that already holds the key does not abort it", %{
    scope: scope,
    user: user
  } do
    {:ok, _row} = Notifications.ensure(scope, attrs(user, "k"))

    assert {:ok, :still_here} =
             Repo.transaction(fn ->
               {:ok, %{is_new: false}} = Notifications.ensure(scope, attrs(user, "k"))
               {:ok, _other} = Notifications.ensure(scope, attrs(user, "k2"))
               :still_here
             end)
  end

  doctest Data.Notifications.Notification

  # AQ-08 §5: the pair is unique, and the CHECKs hold the states together.
  test "the ledger: never twice per channel; skipped carries its reason, sent its time", %{
    org: org,
    user: user
  } do
    n = notification_fixture(org, user)
    now = ~U[2026-11-12 06:00:00Z]
    plan = [%{channel: :email, deliver_after: now, deferred: false}]

    assert [%{state: :pending, attempts: 0}] =
             Deliveries.insert_planned(n, plan, "BEGIN:VCALENDAR", now)

    assert Deliveries.insert_planned(n, plan, nil, now) == []
    assert [%{ics: "BEGIN:VCALENDAR"}] = Deliveries.for_notification(n.id)

    assert_raise Postgrex.Error, ~r/skipped_with_reason/, fn ->
      Repo.query!("UPDATE notification_deliveries SET state = 'skipped'")
    end

    assert_raise Postgrex.Error, ~r/sent_with_time/, fn ->
      Repo.query!("UPDATE notification_deliveries SET state = 'sent'")
    end

    assert_raise Postgrex.Error, ~r/ics_on_email/, fn ->
      Repo.query!("UPDATE notification_deliveries SET channel = 'push'")
    end
  end

  test "a page newest first by keyset, unread, read one's own only, read all", %{
    org: org,
    user: user
  } do
    rows = for n <- 1..3, do: notification_fixture(org, user, dedupe_key: "k#{n}")
    other = notification_fixture(org, user_fixture())

    assert {[a, b], true} = Notifications.page(user.id, limit: 2)
    assert {[c], false} = Notifications.page(user.id, limit: 2, after: {b.inserted_at, b.id})
    assert Enum.sort(Enum.map([a, b, c], & &1.id)) == Enum.sort(Enum.map(rows, & &1.id))

    now = DateTime.utc_now()
    assert Notifications.mark_read(user.id, other.id, now) == nil
    assert %{read_at: %DateTime{}} = Notifications.mark_read(user.id, a.id, now)
    assert Notifications.unread_count(user.id) == 2
    assert {[_one, _two], false} = Notifications.page(user.id, unread: true)
    assert Notifications.mark_all_read(user.id, now) == 2
    assert Notifications.unread_count(user.id) == 0
    assert [%{key: "tasks"}] = Notifications.groups_with_rows(user.id)
    assert {[], false} = Notifications.page(user.id, group: "leads")
  end
end
