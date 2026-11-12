defmodule Core.Meetings.RemindersTest do
  @moduledoc """
  Reminders (AQ-06 §8.3, QP6-16, §13 step 6): at −24 h, −1 h and −10 min
  they reach the customer, the owner and the staff attendees, **once
  each** (the job run twice tells nobody twice); a 24 h job run after the
  1 h mark says nothing; a reschedule's old jobs say nothing; the dev
  clock's catch-up sends what the moved clock makes due.
  """

  use Core.CoreCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Core.Clock
  alias Core.Meetings
  alias Core.Meetings.Reminders
  alias Core.Workers.MeetingReminder

  @now ~U[2026-11-11 09:00:00.000000Z]
  @starts ~U[2026-11-18 09:00:00.000000Z]

  setup do
    on_exit(fn ->
      Clock.unfreeze()
      Application.put_env(:core, :dev_clock, false)
      :persistent_term.erase({Utils.Clock, :offset_seconds})
    end)

    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    corvid = company_fixture(c.org, name: "Corvid Security")
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer", company: corvid)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)

    {:ok, meeting} =
      Meetings.schedule(
        fiza,
        lead.id,
        %{
          "title" => "Technical interview",
          "meeting_kind" => "technical",
          "platform" => "google_meet",
          "starts_at" => DateTime.to_iso8601(@starts),
          "ends_at" => DateTime.to_iso8601(DateTime.add(@starts, 3600)),
          "time_zone" => "Europe/Berlin",
          "attendees" => [%{"user_id" => c.qasim.id}, %{"customer" => true}]
        },
        @now
      )

    Map.merge(c, %{lead: lead, meeting: meeting})
  end

  # The 24 h reminder is `meetings.day_before` since AQ-08 (QP8-4); the
  # 1 h and 10 min ones stay `meetings.reminder`.
  defp reminders do
    for n <- Repo.all(Data.Notifications.Notification),
        n.notification_kind_key in ~w(meetings.reminder meetings.day_before),
        do: {n.user_id, n.dedupe_key, n.title}
  end

  defp kinds_of(offset) do
    for n <- Repo.all(Data.Notifications.Notification),
        n.dedupe_key =~ ":remind:#{offset}:",
        uniq: true,
        do: n.notification_kind_key
  end

  test "planned at creation: three jobs, keyed by (meeting, offset, starts_at), on the scheduling queue",
       c do
    jobs = all_enqueued(worker: MeetingReminder)
    assert Enum.sort(Enum.map(jobs, & &1.args["offset"])) == [10, 60, 1440]
    assert Enum.all?(jobs, &(&1.queue == "scheduling" and &1.args["meeting_id"] == c.meeting.id))

    assert Enum.map(Enum.sort_by(jobs, & &1.scheduled_at, DateTime), & &1.scheduled_at) == [
             ~U[2026-11-17 09:00:00.000000Z],
             ~U[2026-11-18 08:00:00.000000Z],
             ~U[2026-11-18 08:50:00.000000Z]
           ]
  end

  test "−24 h, −1 h, −10 min: the customer, the owner, the staff attendee, once each; twice is still once",
       c do
    args = fn offset ->
      %{
        "meeting_id" => c.meeting.id,
        "offset" => offset,
        "starts_at" => DateTime.to_iso8601(@starts)
      }
    end

    Clock.freeze(~U[2026-11-17 09:05:00.000000Z])
    assert :ok = perform_job(MeetingReminder, args.(1440))
    assert :ok = perform_job(MeetingReminder, args.(1440))

    who = reminders() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert who == Enum.sort([c.tanweer.user_id, c.fiza.id, c.qasim.id])
    assert kinds_of(1440) == ["meetings.day_before"]

    assert {_user, "meeting:" <> _,
            "Technical interview with Corvid Security in 24 hours · 14:00 PKT · Google Meet"} =
             Enum.find(reminders(), &(elem(&1, 0) == c.fiza.id))

    Clock.freeze(~U[2026-11-18 08:05:00.000000Z])
    # The 24 h job, late: nothing. The 1 h one: once each.
    assert Reminders.remind(c.meeting.id, 1440, DateTime.to_iso8601(@starts), Clock.now()) ==
             :stale

    assert :ok = perform_job(MeetingReminder, args.(60))
    assert :ok = perform_job(MeetingReminder, args.(60))
    assert length(reminders()) == 6
    assert kinds_of(60) == ["meetings.reminder"]

    Clock.freeze(~U[2026-11-18 08:52:00.000000Z])
    assert Reminders.remind(c.meeting.id, 10, DateTime.to_iso8601(@starts), Clock.now()) == :sent
    assert Reminders.remind(c.meeting.id, 10, DateTime.to_iso8601(@starts), Clock.now()) == :sent
    assert length(reminders()) == 9

    assert {_u, _k,
            "Technical interview with Corvid Security in 10 minutes · 14:00 PKT · Google Meet"} =
             Enum.find(
               reminders(),
               &(elem(&1, 0) == c.tanweer.user_id and elem(&1, 1) =~ ":remind:10:")
             )

    Clock.freeze(~U[2026-11-18 09:01:00.000000Z])

    assert Reminders.remind(c.meeting.id, 10, DateTime.to_iso8601(@starts), Clock.now()) ==
             :started
  end

  test "a reschedule re-plans: the old jobs say nothing; a cancel says nothing at all", c do
    {:ok, _moved} =
      Meetings.reschedule(
        scope_for(c.fiza),
        c.meeting.id,
        %{
          "starts_at" => "2026-11-19T09:00:00Z",
          "ends_at" => "2026-11-19T10:00:00Z"
        },
        @now
      )

    at = ~U[2026-11-18 08:55:00.000000Z]
    assert Reminders.remind(c.meeting.id, 10, DateTime.to_iso8601(@starts), at) == :moved
    assert reminders() == []

    {:ok, _cancelled} = Meetings.cancel(scope_for(c.fiza), c.meeting.id, %{}, @now)

    assert Reminders.remind(
             c.meeting.id,
             60,
             "2026-11-19T09:00:00.000000Z",
             ~U[2026-11-19 08:30:00Z]
           ) == :moved

    assert Reminders.remind(Ecto.UUID.generate(), 60, "2026-11-19T09:00:00Z", @now) == :gone
  end

  test "the dev clock: moved a day on, the catch-up sends the reminder now due, once", c do
    Application.put_env(:core, :dev_clock, true)
    real = DateTime.utc_now()
    starts = real |> DateTime.add(86_400 + 30 * 60, :second) |> DateTime.truncate(:second)

    {:ok, soon} =
      Meetings.schedule(
        scope_for(c.fiza),
        c.lead.id,
        %{
          "title" => "Final",
          "meeting_kind" => "final",
          "platform" => "zoom",
          "starts_at" => DateTime.to_iso8601(starts),
          "ends_at" => DateTime.to_iso8601(DateTime.add(starts, 3600)),
          "time_zone" => "Asia/Karachi"
        },
        real
      )

    :ok = Clock.set_offset_days(1)
    now = Clock.now()
    assert Reminders.nearest(Data.Meetings.get(c.org.id, soon.id), now) == 60
    assert %{meetings: 1} = Reminders.catch_up(now)
    assert %{meetings: 1} = Reminders.catch_up(now)

    final = for {u, k, t} <- reminders(), k =~ soon.id, do: {u, t}
    assert length(final) == 2
    assert Enum.all?(final, fn {_u, t} -> t =~ "Final with Corvid Security in 1 hour" end)
  end
end
