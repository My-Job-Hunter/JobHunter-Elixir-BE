defmodule Core.Notifications.DigestsTest do
  @moduledoc """
  The digest scan (AQ-08 §7.4, §13 step 6): once their time has passed
  today, a person with unread notifications of digest kinds gets one
  `account.digest`, grouped, planned for email at once; the next scans that
  day add nothing; nothing unread means no digest; a group whose digest
  switch is off is left out. Run twice, as every scan is.
  """

  use Core.CoreCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Core.Notifications.Digests
  alias Core.Workers.DigestScan
  alias Data.Notifications.{Deliveries, Notification}

  # 08:05 in Karachi.
  @now ~U[2026-11-12 03:05:00.000000Z]

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    qasim = member_fixture(team, :member, user_fixture(display_name: "Qasim"))
    muaz = member_fixture(team, :member, user_fixture(display_name: "Muaz"))
    %{org: org, qasim: qasim, muaz: muaz}
  end

  defp unread(org, user, kind, title),
    do: notification_fixture(org, user, notification_kind_key: kind, title: title)

  defp digests(user) do
    for n <- Repo.all(Notification),
        n.user_id == user.id and n.notification_kind_key == "account.digest",
        do: n
  end

  test "one digest a local day, grouped, emailed at once; the next scans add nothing", c do
    unread(c.org, c.qasim, "tasks.overdue", "“Fix the CV” is overdue")
    unread(c.org, c.qasim, "leads.follow_up_due", "Follow up on “Golang”")
    unread(c.org, c.qasim, "leads.archive_warned", "“Golang” will be archived in 7 days")
    # Not a digest kind: it went by push, so it isn't repeated.
    unread(c.org, c.qasim, "tasks.assigned", "Hira gave you “Fix the CV”")

    assert Digests.scan(@now) == 1
    assert [digest] = digests(c.qasim)
    assert digest.title == "3 things you haven't read"
    assert digest.link_path == "/notifications?unread=1"
    assert digest.dedupe_key == "digest:#{c.qasim.id}:2026-11-12"

    assert digest.body ==
             "Tasks · 1\nLeads · 2\n\n“Fix the CV” is overdue\nFollow up on “Golang”\n" <>
               "“Golang” will be archived in 7 days"

    assert [%{channel: :email, deliver_after: @now, deferred: false}] =
             Deliveries.for_notification(digest.id)

    # Twice, and through the worker: still one.
    assert Digests.scan(@now) == 0
    assert :ok = perform_job(DigestScan, %{})
    assert Digests.scan(DateTime.add(@now, 3600, :second)) == 0
    assert length(digests(c.qasim)) == 1
  end

  test "nothing unread, no digest; read ones don't count", c do
    n = unread(c.org, c.muaz, "tasks.overdue", "“Fix the CV” is overdue")
    Data.Notifications.mark_read(c.muaz.id, n.id, @now)

    assert Digests.scan(@now) == 0
    assert digests(c.muaz) == []
  end

  test "not before the person's time, nor when the digest is off; a group switched off is left out",
       c do
    unread(c.org, c.qasim, "tasks.overdue", "“Fix the CV” is overdue")
    unread(c.org, c.qasim, "conversations.triage_new", "New in Triage: Mei Chen")

    # 07:55 in Karachi.
    assert Digests.scan(~U[2026-11-12 02:55:00.000000Z]) == 0

    {:ok, _} = Data.Accounts.put_settings(c.qasim.id, %{digest_on: false})
    assert Digests.scan(@now) == 0

    {:ok, _} = Data.Accounts.put_settings(c.qasim.id, %{digest_on: true})
    preference_fixture(c.qasim, "tasks", %{digest: false})

    assert Digests.scan(@now) == 1

    assert [
             %{
               title: "1 thing you haven't read",
               body: "Conversations · 1\n\nNew in Triage: Mei Chen"
             }
           ] =
             digests(c.qasim)
  end

  test "the next day says only what came since the last digest", c do
    unread(c.org, c.qasim, "tasks.overdue", "“Fix the CV” is overdue")
    assert Digests.scan(@now) == 1

    tomorrow = DateTime.add(@now, 86_400, :second)
    assert Digests.scan(tomorrow) == 0

    unread(c.org, c.qasim, "tasks.due_soon", "“Send the rate” is due tomorrow")
    assert Digests.scan(tomorrow) == 1

    assert [_first, %{title: "1 thing you haven't read", body: body}] =
             c.qasim |> digests() |> Enum.sort_by(& &1.dedupe_key)

    assert body == "Tasks · 1\n\n“Send the rate” is due tomorrow"
  end
end
