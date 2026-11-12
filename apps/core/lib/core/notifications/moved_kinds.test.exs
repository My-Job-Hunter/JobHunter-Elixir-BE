defmodule Core.Notifications.MovedKindsTest do
  @moduledoc """
  The kinds P8 moves (AQ-08 §6, §14, QP8-4, QP8-5): a customer's lead
  reaching an interview stage, an offer or *Hired* is
  `leads.customer_milestone` (push and email), any other customer-visible
  move stays `leads.customer_update`; a reply reaches the customer too when
  the team shows conversations, and not after a lead turns that off; a
  meeting's emails carry its invite.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Conversations.Messages
  alias Core.Leads
  alias Core.Leads.Act
  alias Data.Notifications.{Deliveries, Notification}

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()

    job =
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        title: "Backend Developer",
        company: company_fixture(c.org, name: "Bamboo Invest")
      )

    Map.put(c, :job, job)
  end

  defp notified(user_id) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user_id and like(n.notification_kind_key, "leads.customer_%"),
        order_by: [asc: n.inserted_at, asc: n.id]
      )
    )
  end

  defp move(lead, params) do
    from = %{"state" => to_string(lead.state), "stage" => lead.stage && lead.stage.key}
    verb = if params["outcome"], do: :finish, else: :move

    {:ok, moved} =
      Act.run(scope_for(lead.hira), verb, lead.id, Map.put(params, "from", from), @now)

    Map.put(moved, :hira, lead.hira)
  end

  test "an interview stage, an offer and Hired are milestones; the rest stay updates", c do
    {:ok, sheet} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => c.job.id, "profile_id" => c.golang.id, "as" => "apply"},
        @now
      )

    lead = Map.put(sheet, :hira, c.hira)

    lead
    |> move(%{"state" => "in_progress", "stage" => "recruiter_screen"})
    |> move(%{"state" => "in_progress", "stage" => "technical_1"})
    |> move(%{"state" => "in_progress", "stage" => "offer"})
    |> move(%{"outcome" => "hired"})

    assert [
             {"leads.customer_update", "Fiza applied to " <> _},
             {"leads.customer_update", "Hira moved your application " <> screen},
             {"leads.customer_milestone", "Hira moved your application " <> interview},
             {"leads.customer_milestone", "Hira moved your application " <> offer},
             {"leads.customer_milestone", "Hira marked your application " <> _hired}
           ] = for(n <- notified(c.tanweer.user_id), do: {n.notification_kind_key, n.title})

    assert screen =~ "to Recruiter screen."
    assert interview =~ "to Technical interview 1."
    assert offer =~ "to Offer."

    # A milestone emails the customer (after the wait); an update stays in the bell.
    [milestone | _] =
      Enum.filter(
        notified(c.tanweer.user_id),
        &(&1.notification_kind_key == "leads.customer_milestone")
      )

    assert [%{channel: :email}] = Deliveries.for_notification(milestone.id)
  end

  test "a reply reaches the customer while the team shows conversations, and not after", c do
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)

    omar =
      contact_fixture(scope_for(c.fiza),
        name: "Omar Haddad",
        handles: [{:email, "omar@corvid.example"}]
      )

    log = fn body ->
      {:ok, _conv} =
        Messages.create(
          scope_for(c.hira),
          %{
            "lead_id" => lead.id,
            "direction" => "in",
            "from" => %{"kind" => "contact", "contact_id" => omar.id},
            "sent_at" => "2026-11-10T10:00:00Z",
            "body_md" => body
          },
          @now
        )
    end

    replies = fn user_id ->
      for n <- Repo.all(Notification),
          n.user_id == user_id and n.notification_kind_key == "conversations.reply_received",
          do: n
    end

    log.("Can we talk Thursday?")

    assert [%{title: "Omar Haddad replied on " <> _, actor_user_id: nil} = told] =
             replies.(c.tanweer.user_id)

    assert told.link_path == "/applications/#{lead.id}"
    assert [%{link_path: "/leads/" <> _}] = replies.(c.fiza.id)

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    log.("Or Friday?")
    assert length(replies.(c.tanweer.user_id)) == 1
    assert length(replies.(c.fiza.id)) == 2
  end

  test "a meeting's emails carry its invite: REQUEST when scheduled, CANCEL when cancelled", c do
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)

    {:ok, meeting} =
      Core.Meetings.schedule(
        scope_for(c.fiza),
        lead.id,
        %{
          "title" => "Technical interview",
          "meeting_kind" => "technical",
          "platform" => "google_meet",
          "starts_at" => "2026-11-18T09:00:00Z",
          "ends_at" => "2026-11-18T10:00:00Z",
          "time_zone" => "Europe/Berlin"
        },
        @now
      )

    [scheduled] =
      for n <- Repo.all(Notification),
          n.user_id == c.tanweer.user_id,
          n.notification_kind_key == "meetings.scheduled",
          do: n

    assert [%{channel: :email, ics: ics, deliver_after: at}] =
             Deliveries.for_notification(scheduled.id)

    assert ics =~ "METHOD:REQUEST" and ics =~ "UID:#{meeting.id}@autoqare"
    # A meeting's email goes at once.
    assert DateTime.diff(at, DateTime.utc_now(), :second) |> abs() < 60

    {:ok, _cancelled} = Core.Meetings.cancel(scope_for(c.fiza), meeting.id, %{}, @now)

    [changed] =
      for n <- Repo.all(Notification),
          n.user_id == c.tanweer.user_id,
          n.notification_kind_key == "meetings.changed",
          do: n

    assert [%{ics: cancel}] = Deliveries.for_notification(changed.id)
    assert cancel =~ "METHOD:CANCEL" and cancel =~ "STATUS:CANCELLED"
  end
end
