defmodule Notifire.DeliveryTest do
  @moduledoc """
  The far side of the seam (AQ-08 §7.2, §11.4), against a real database
  and the test mailbox. Nothing here goes through `core`: the rows are
  written as the seam writes them (`delivery_fixture/2`), and delivery only
  ever sees rows. **Every run twice.**
  """

  use Notifire.NotifireCase, async: true

  # A refused email logs a warning, as it should; not in the test output.
  @moduletag :capture_log

  alias Data.Notifications.{Deliveries, Delivery}
  alias Notifire.Delivery, as: Sweep
  alias Notifire.Push.Outbox

  @now ~U[2026-11-12 06:00:00.000000Z]

  setup do
    org = organisation_fixture()
    fiza = user_fixture(display_name: "Fiza Malik", email: "fiza@example.com")
    customer = customer_fixture(org, [], login: true, login_name: "Muhammad Tanweer")
    tanweer = Data.Accounts.get_user(customer.user_id)
    %{org: org, fiza: fiza, tanweer: tanweer}
  end

  defp notice(c, user, kind, attrs \\ %{}) do
    notification_fixture(
      c.org,
      user,
      Map.merge(
        %{
          notification_kind_key: kind,
          title: "Hira asked you to approve “Golang CV”",
          body: "Before Friday, please.",
          link_path: "/approvals/7?team=3"
        },
        attrs
      )
    )
  end

  defp state(row), do: Repo.get!(Delivery, row.id)

  describe "email" do
    test "sent once, when due, in the row's words, with the link into the console and the footer",
         c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: DateTime.add(@now, 600, :second))

      # Inside its ten minutes: not yet.
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      refute_email_sent()

      at = DateTime.add(@now, 601, :second)
      assert Sweep.run(at) == %{sent: 1, skipped: 0, failed: 0}
      assert Sweep.run(at) == %{sent: 0, skipped: 0, failed: 0}

      assert_email_sent(fn email ->
        assert email.to == [{"Fiza Malik", "fiza@example.com"}]
        assert email.from == {"AutoQare", "hello@autoqare.com"}
        assert email.subject == "Hira asked you to approve “Golang CV”"

        assert email.text_body ==
                 "Before Friday, please.\n\nhttp://localhost:5800/approvals/7?team=3\n\n" <>
                   "Change what AutoQare emails you: http://localhost:5800/notifications?sheet=settings\n"
      end)

      assert %{state: :sent, sent_at: ^at} = state(row)
    end

    test "a customer's opens the portal; with no body the title stands in", c do
      n =
        notice(c, c.tanweer, "leads.customer_milestone", %{
          body: nil,
          title: "The team moved your application to Offer.",
          link_path: "/applications/9"
        })

      delivery_fixture(n, channel: :email, deliver_after: @now)

      assert %{sent: 1} = Sweep.run(@now)

      assert_email_sent(fn email ->
        assert email.text_body =~
                 "The team moved your application to Offer.\n\nhttp://localhost:5801/applications/9\n\n"

        assert email.text_body =~ "http://localhost:5801/notifications?sheet=settings"
      end)
    end

    test "read before its time, it is skipped; a meeting's still goes, with its invite", c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.fiza.id, n.id, @now)

      meeting =
        notice(c, c.fiza, "meetings.scheduled", %{title: "Hira scheduled Technical interview"})

      ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
      invite = delivery_fixture(meeting, channel: :email, deliver_after: @now, ics: ics)
      Data.Notifications.mark_read(c.fiza.id, meeting.id, @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :read} = state(row)
      assert %{state: :sent} = state(invite)

      assert_email_sent(fn email ->
        assert email.subject == "Hira scheduled Technical interview"
        assert [attachment] = email.attachments
        assert attachment.filename == "invite.ics"
        assert attachment.content_type == "text/calendar; method=REQUEST"
        assert attachment.data == ics
      end)
    end

    test "the digest goes even when read, with its lines, its link and its time", c do
      {:ok, _} = Data.Accounts.put_settings(c.fiza.id, %{digest_time: ~T[07:30:00]})

      n =
        notice(c, c.fiza, "account.digest", %{
          title: "2 things you haven't read",
          body: "Tasks · 2\n\nA is overdue\nB is overdue",
          link_path: "/notifications?unread=1"
        })

      delivery_fixture(n, channel: :email, deliver_after: @now)
      Data.Notifications.mark_read(c.fiza.id, n.id, @now)

      assert %{sent: 1} = Sweep.run(@now)

      assert_email_sent(fn email ->
        assert email.subject == "2 things you haven't read"

        assert email.text_body ==
                 "Tasks · 2\n\nA is overdue\nB is overdue\n\n" <>
                   "Open them: http://localhost:5800/notifications?unread=1\n\n" <>
                   "Sent at 07:30 your time. Change the time or turn it off: " <>
                   "http://localhost:5800/notifications?sheet=settings\n"
      end)
    end

    test "a refusal is recorded, never swallowed: retried on the next two sweeps, then failed",
         c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      failing = [mailer: [adapter: Notifire.FailingAdapter]]

      assert Sweep.run(@now, failing) == %{sent: 0, skipped: 0, failed: 1}
      retry = DateTime.add(@now, 300, :second)

      assert %{state: :pending, attempts: 1, error: "mailbox unavailable", deliver_after: ^retry} =
               state(row)

      # Not due again until five minutes on.
      assert Sweep.run(@now, failing) == %{sent: 0, skipped: 0, failed: 0}
      assert Sweep.run(retry, failing) == %{sent: 0, skipped: 0, failed: 1}
      last = DateTime.add(retry, 300, :second)
      assert Sweep.run(last, failing) == %{sent: 0, skipped: 0, failed: 1}
      assert %{state: :failed, attempts: 3, error: "mailbox unavailable"} = state(row)

      assert Sweep.run(DateTime.add(last, 3600, :second), failing) == %{
               sent: 0,
               skipped: 0,
               failed: 0
             }
    end
  end

  describe "preferences at send time" do
    test "a channel turned off since the row was planned is skipped; Account can't be", c do
      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :email, deliver_after: @now)
      preference_fixture(c.fiza, "approvals", %{email: false})

      digest = notice(c, c.fiza, "account.digest", %{title: "1 thing you haven't read"})
      kept = delivery_fixture(digest, channel: :email, deliver_after: @now)
      preference_fixture(c.fiza, "account", %{email: false})

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :preference_off} = state(row)
      assert %{state: :sent} = state(kept)
    end
  end

  describe "push (test records, never sends)" do
    test "sent to the person's browsers on their app, kept in the outbox; the tag is the notification",
         c do
      push_subscription_fixture(c.fiza, app: :team, endpoint: "https://push.example/fiza-team")

      push_subscription_fixture(c.fiza,
        app: :client,
        endpoint: "https://push.example/fiza-client"
      )

      n = notice(c, c.fiza, "approvals.requested")
      row = delivery_fixture(n, channel: :push, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 0, failed: 0}
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      assert %{state: :sent} = state(row)

      assert [%{app: :team, endpoint: "https://push.example/fiza-team", payload: payload}] =
               Enum.filter(Outbox.list(), &(&1.user_id == c.fiza.id))

      assert payload == %{
               title: "Hira asked you to approve “Golang CV”",
               body: "Before Friday, please.",
               tag: n.id,
               url: "/approvals/7?team=3&n=#{n.id}"
             }
    end

    test "nowhere to send it: skipped, no target; a customer's goes to the portal's browsers",
         c do
      n = notice(c, c.fiza, "tasks.assigned")
      row = delivery_fixture(n, channel: :push, deliver_after: @now)

      push_subscription_fixture(c.tanweer, app: :client, endpoint: "https://push.example/tanweer")
      milestone = notice(c, c.tanweer, "leads.customer_milestone", %{link_path: nil})
      told = delivery_fixture(milestone, channel: :push, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 1, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :no_target} = state(row)
      assert %{state: :sent} = state(told)

      assert [%{app: :client, payload: %{url: url}}] =
               Enum.filter(Outbox.list(), &(&1.user_id == c.tanweer.id))

      assert url == "/notifications?n=#{milestone.id}"
    end
  end

  describe "the extension's rows" do
    test "nobody claimed within a day: skipped, no target; younger ones wait for the poll", c do
      n = notice(c, c.fiza, "conversations.reply_received")

      old =
        delivery_fixture(n,
          channel: :extension,
          deliver_after: DateTime.add(@now, -86_401, :second)
        )

      fresh =
        notice(c, c.fiza, "conversations.reply_received")
        |> delivery_fixture(channel: :extension, deliver_after: @now)

      assert Sweep.run(@now) == %{sent: 0, skipped: 1, failed: 0}
      assert Sweep.run(@now) == %{sent: 0, skipped: 0, failed: 0}
      assert %{state: :skipped, skip_reason: :no_target} = state(old)
      assert %{state: :pending} = state(fresh)
      assert length(Deliveries.for_user(c.fiza.id)) == 2
    end
  end
end
