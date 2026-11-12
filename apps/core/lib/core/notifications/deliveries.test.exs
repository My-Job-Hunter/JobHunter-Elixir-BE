defmodule Core.Notifications.DeliveriesTest do
  @moduledoc """
  The seam (AQ-08 §7.1, QP8-1): `Core.Notifications.ensure/2` writes the
  row and, when it is new, its deliveries in the same transaction, with the
  delivery worker enqueued by its configured name when a push or email is
  due now. Ensured again it plans nothing; rolled back it leaves nothing.
  Quiet hours hold rows to the window's end, and a changed window re-plans
  them (`PUT /me/settings`).
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Notifications
  alias Data.Notifications.Deliveries

  @now ~U[2026-11-12 06:00:00.000000Z]
  @worker "Notifire.Workers.DeliveryWorker"

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    fiza = member_fixture(team, :member, user_fixture(display_name: "Fiza"))
    customer = customer_fixture(org, [team], login: true)
    %{org: org, team: team, fiza: fiza, customer: customer, scope: Data.Scope.system(org)}
  end

  defp ensure(scope, user_id, kind, now \\ @now, extra \\ %{}) do
    Notifications.ensure(
      scope,
      Map.merge(
        %{
          user_id: user_id,
          notification_kind_key: kind,
          title: "Hira asked you to approve “Golang CV”",
          link_path: "/approvals/1",
          dedupe_key: "#{kind}:#{System.unique_integer([:positive])}"
        },
        extra
      ),
      now
    )
  end

  defp rows(n), do: for(d <- Deliveries.for_notification(n.id), do: {d.channel, d.deliver_after})

  test "a new row plans its deliveries; ensured again it plans nothing; the worker is enqueued by name",
       c do
    push_subscription_fixture(c.fiza)
    device_fixture(scope_for(c.fiza))

    {:ok, n} = ensure(c.scope, c.fiza.id, "approvals.requested")
    assert n.is_new

    assert rows(n) == [
             {:push, @now},
             {:email, DateTime.add(@now, 600, :second)}
           ]

    assert [job] = all_enqueued(worker: @worker)
    assert job.queue == "notifications"

    {:ok, again} =
      Notifications.ensure(
        c.scope,
        Map.from_struct(n) |> Map.take(~w(user_id notification_kind_key title dedupe_key)a),
        @now
      )

    refute again.is_new
    assert length(Deliveries.for_notification(n.id)) == 2

    # A reply: push and the pop-up, both at once.
    {:ok, reply} = ensure(c.scope, c.fiza.id, "conversations.reply_received")
    assert rows(reply) == [{:push, @now}, {:extension, @now}]

    # Unique for two seconds: a burst is one sweep.
    assert [_one] = all_enqueued(worker: @worker)
  end

  test "who can have what: no browser, no push; a customer never the extension, and push only from the portal",
       c do
    {:ok, n} = ensure(c.scope, c.fiza.id, "conversations.reply_received")
    assert rows(n) == []

    customer = Data.Accounts.get_user(c.customer.user_id)
    push_subscription_fixture(customer, app: :team)
    device_fixture(scope_for(c.fiza))

    {:ok, reply} = ensure(c.scope, customer.id, "conversations.reply_received")
    assert rows(reply) == []

    push_subscription_fixture(customer, app: :client)
    {:ok, reply} = ensure(c.scope, customer.id, "conversations.reply_received")
    assert rows(reply) == [{:push, @now}]

    # A milestone: push and email, the email after its wait.
    {:ok, milestone} = ensure(c.scope, customer.id, "leads.customer_milestone")
    assert [{:push, @now}, {:email, _later}] = rows(milestone)
  end

  test "only push or email due now enqueues the worker; in-app alone plans nothing", c do
    {:ok, n} = ensure(c.scope, c.fiza.id, "approvals.requested")
    assert rows(n) == [{:email, DateTime.add(@now, 600, :second)}]
    assert all_enqueued(worker: @worker) == []

    {:ok, bell} = ensure(c.scope, c.fiza.id, "tasks.completed")
    assert rows(bell) == []

    {:ok, digest_only} = ensure(c.scope, c.fiza.id, "tasks.overdue")
    assert rows(digest_only) == []
    assert all_enqueued(worker: @worker) == []

    # A meeting's email goes at once, so it enqueues.
    {:ok, _meeting} = ensure(c.scope, c.fiza.id, "meetings.scheduled")
    assert [_job] = all_enqueued(worker: @worker)
  end

  test "a rolled-back notification plans nothing and enqueues nothing", c do
    push_subscription_fixture(c.fiza)

    assert {:error, :changed_my_mind} =
             Repo.transaction(fn ->
               {:ok, _n} = ensure(c.scope, c.fiza.id, "tasks.assigned")
               Repo.rollback(:changed_my_mind)
             end)

    assert Repo.aggregate(Data.Notifications.Delivery, :count) == 0
    assert all_enqueued(worker: @worker) == []
  end

  test "a switch off plans nothing for that channel; Account ignores switches", c do
    push_subscription_fixture(c.fiza)
    preference_fixture(c.fiza, "approvals", %{email: false})

    {:ok, n} = ensure(c.scope, c.fiza.id, "approvals.requested")
    assert rows(n) == [{:push, @now}]

    {:ok, digest} = ensure(c.scope, c.fiza.id, "account.digest")
    assert rows(digest) == [{:email, @now}]
  end

  describe "quiet hours (22:00–08:00 in Karachi)" do
    # 23:00 in Karachi; the window ends at 08:00 there, 03:00 UTC.
    @night ~U[2026-11-12 18:00:00.000000Z]
    @opens ~U[2026-11-13 03:00:00.000000Z]

    setup c do
      {:ok, _settings} =
        Data.Accounts.put_settings(c.fiza.id, %{
          quiet_hours_start: ~T[22:00:00],
          quiet_hours_end: ~T[08:00:00]
        })

      push_subscription_fixture(c.fiza)
      device_fixture(scope_for(c.fiza))
      :ok
    end

    test "push, email and pop-ups are held to the window's end; the bell row is there at once; a reminder passes",
         c do
      {:ok, n} = ensure(c.scope, c.fiza.id, "approvals.requested", @night)
      assert Repo.get(Data.Notifications.Notification, n.id)

      assert [%{deferred: true, deliver_after: @opens}, %{deferred: true, deliver_after: @opens}] =
               Deliveries.for_notification(n.id)

      {:ok, reply} = ensure(c.scope, c.fiza.id, "conversations.reply_received", @night)
      assert Enum.all?(Deliveries.for_notification(reply.id), &(&1.deliver_after == @opens))
      assert all_enqueued(worker: @worker) == []

      {:ok, reminder} = ensure(c.scope, c.fiza.id, "meetings.reminder", @night)

      assert [%{channel: :push, deferred: false, deliver_after: @night}] =
               Deliveries.for_notification(reminder.id)

      assert [_job] = all_enqueued(worker: @worker)
    end

    test "PUT /me/settings with another window re-plans the held rows; off lets them go now", c do
      {:ok, n} = ensure(c.scope, c.fiza.id, "approvals.requested", @night)
      later = DateTime.add(@night, 60, :second)

      # 21:00 → 23:30 in Karachi: held to 23:30 there, 18:30 UTC.
      {:ok, _settings} =
        Core.Accounts.put_settings(
          scope_for(c.fiza),
          %{"quiet_hours_start" => "21:00:00", "quiet_hours_end" => "23:30:00"},
          later
        )

      assert Enum.all?(
               Deliveries.for_notification(n.id),
               &(&1.deferred and &1.deliver_after == ~U[2026-11-12 18:30:00.000000Z])
             )

      {:ok, _settings} =
        Core.Accounts.put_settings(
          scope_for(c.fiza),
          %{"quiet_hours_start" => nil, "quiet_hours_end" => nil},
          later
        )

      # Push goes now; the email keeps its ten minutes from when it was written.
      assert [
               %{channel: :push, deferred: false, deliver_after: ^later},
               %{channel: :email, deferred: false, deliver_after: email_at}
             ] = Deliveries.for_notification(n.id)

      assert email_at == DateTime.add(@night, 600, :second)
      assert [_job] = all_enqueued(worker: @worker)
    end
  end
end
