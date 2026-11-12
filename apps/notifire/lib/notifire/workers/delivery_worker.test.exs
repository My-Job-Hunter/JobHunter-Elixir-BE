defmodule Notifire.Workers.DeliveryWorkerTest do
  @moduledoc """
  The sweep's worker (AQ-08 §7.2, §7.3, QP8-22): it reads `Utils.Clock`, so
  a row held by quiet hours is released by **moving the clock** — frozen in
  a test, or the dev clock's offset a run moves — and run twice it sends
  nothing twice. Not async: it moves the whole VM's dev clock and turns
  push's keys off for one test.
  """

  use Notifire.NotifireCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Data.Notifications.Delivery
  alias Notifire.Push.Outbox
  alias Notifire.Workers.DeliveryWorker

  @now ~U[2026-11-12 18:00:00.000000Z]
  # Where a 22:00–08:00 window in Karachi ends: 08:00 there, 03:00 UTC.
  @opens ~U[2026-11-13 03:00:00.000000Z]

  setup do
    previous = Application.get_env(:core, :dev_clock)

    on_exit(fn ->
      Application.put_env(:core, :dev_clock, true)
      Utils.Clock.set_offset_days(0)
      Application.put_env(:core, :dev_clock, previous)
      Utils.Clock.unfreeze()
    end)

    org = organisation_fixture()
    fiza = user_fixture(display_name: "Fiza")
    push_subscription_fixture(fiza)

    n =
      notification_fixture(org, fiza,
        notification_kind_key: "approvals.requested",
        title: "Hira asked you to approve “Golang CV”"
      )

    held = delivery_fixture(n, channel: :push, deliver_after: @opens, deferred: true, now: @now)
    %{fiza: fiza, held: held}
  end

  test "held to the window's end: nothing before it; moving the clock past it sends it once", c do
    Utils.Clock.freeze(DateTime.add(@opens, -60, :second))
    assert {:ok, %{sent: 0, skipped: 0, failed: 0}} = perform_job(DeliveryWorker, %{})
    assert %{state: :pending, deferred: true} = Repo.get!(Delivery, c.held.id)

    Utils.Clock.freeze(@opens)
    assert {:ok, %{sent: 1}} = perform_job(DeliveryWorker, %{})
    assert {:ok, %{sent: 0, skipped: 0, failed: 0}} = perform_job(DeliveryWorker, %{})
    assert %{state: :sent, sent_at: @opens} = Repo.get!(Delivery, c.held.id)
  end

  test "the dev clock's offset releases it too: the same now `core` reads (`Core.Clock` delegates)",
       c do
    Application.put_env(:core, :dev_clock, true)
    # A row held a day ahead of the real time.
    tomorrow = DateTime.add(DateTime.utc_now(), 86_400, :second)
    Repo.update_all(Delivery, set: [deliver_after: tomorrow])

    assert {:ok, %{sent: 0}} = perform_job(DeliveryWorker, %{})
    :ok = Utils.Clock.set_offset_days(2)
    assert {:ok, %{sent: 1}} = perform_job(DeliveryWorker, %{})
    assert %{state: :sent} = Repo.get!(Delivery, c.held.id)
  end

  test "a `now` in the job's args wins; the outbox keeps the push and empties on clear", c do
    Outbox.clear()

    assert {:ok, %{sent: 1}} =
             perform_job(DeliveryWorker, %{"now" => DateTime.to_iso8601(@opens)})

    assert [%{user_id: user_id}] = Outbox.list()
    assert user_id == c.fiza.id

    assert Outbox.clear() == :ok
    assert Outbox.list() == []
  end

  test "without VAPID keys push is off: the row is skipped, no target, never failed", c do
    keys = Application.get_env(:notifire, :web_push)
    Application.delete_env(:notifire, :web_push)
    on_exit(fn -> Application.put_env(:notifire, :web_push, keys) end)

    refute Notifire.Push.configured?()

    assert {:ok, %{sent: 0, skipped: 1, failed: 0}} =
             perform_job(DeliveryWorker, %{"now" => DateTime.to_iso8601(@opens)})

    assert %{state: :skipped, skip_reason: :no_target} = Repo.get!(Delivery, c.held.id)
  end
end
