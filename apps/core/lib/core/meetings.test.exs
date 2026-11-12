defmodule Core.MeetingsTest do
  @moduledoc """
  Meetings (AQ-06 §8, §13 step 6): two interview rounds on the Corvid
  lead, scheduled in CET; "Move to *Technical interview 1*?" taken through
  P4a's move; a clash warned on another lead (named in the team, "another
  meeting" from another team); reschedule, cancel, done and no-show with
  their events and `sequence`; the ICS file; *Next* and the banner; the
  Meetings page by `peer_leads` and the customer's own.
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Meetings

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    corvid = company_fixture(c.org, name: "Corvid Security")
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer", company: corvid)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)
    Map.merge(c, %{fiza_scope: fiza, lead: lead, corvid: corvid})
  end

  defp body(c, attrs \\ %{}) do
    Map.merge(
      %{
        "title" => "Technical interview",
        "meeting_kind" => "technical",
        "platform" => "google_meet",
        "join_url" => "https://meet.google.com/abc-defg-hij",
        "starts_at" => "2026-11-18T09:00:00Z",
        "ends_at" => "2026-11-18T10:00:00Z",
        "time_zone" => "Europe/Berlin",
        "attendees" => [%{"user_id" => c.fiza.id}, %{"customer" => true}]
      },
      attrs
    )
  end

  test "two rounds: scheduled, the stage offered and taken, events, notices, reminders planned",
       c do
    assert {:ok,
            %{
              stage_offer: %{key: "technical_1", words: "Move to Technical interview 1?"},
              clash: nil
            }} =
             Meetings.clash(c.fiza_scope, %{
               "lead_id" => c.lead.id,
               "starts_at" => "2026-11-18T09:00:00Z",
               "ends_at" => "2026-11-18T10:00:00Z",
               "meeting_kind" => "technical"
             })

    assert {:ok, round1} =
             Meetings.schedule(
               c.fiza_scope,
               c.lead.id,
               body(c, %{"move_to_stage" => "technical_1"}),
               @now
             )

    assert round1.status == :scheduled and round1.sequence == 0 and round1.clash == nil
    assert round1.lead.company == %{id: c.corvid.id, name: "Corvid Security"}
    assert Enum.map(round1.attendees, & &1.kind) == [:user, :customer]
    assert round1.can == %{reschedule: true, cancel: true, done: true, no_show: true, edit: true}
    assert Data.Leads.reload(c.lead).stage.key == "technical_1"

    assert {:ok, round2} =
             Meetings.schedule(
               c.fiza_scope,
               c.lead.id,
               body(c, %{
                 "title" => "Final",
                 "meeting_kind" => "final",
                 "starts_at" => "2026-11-25T09:00:00Z",
                 "ends_at" => "2026-11-25T10:00:00Z"
               }),
               @now
             )

    assert round2.title == "Final"

    kinds = for e <- Data.Leads.events(c.lead.id), do: {e.kind, e.visibility}
    assert Enum.count(kinds, &(&1 == {:meeting_scheduled, :customer})) == 2
    assert {:stage_moved, :customer} in kinds

    # Tanweer and Fiza's bell: Tanweer told of both (Fiza acted); three reminder jobs each.
    told =
      for n <- Repo.all(Data.Notifications.Notification),
          n.notification_kind_key == "meetings.scheduled",
          do: n

    assert Enum.map(told, & &1.user_id) |> Enum.uniq() == [c.tanweer.user_id]

    assert hd(told).title =~
             "scheduled Technical interview with Corvid Security · Wed 18 Nov 14:00 PKT"

    assert length(all_enqueued(worker: Core.Workers.MeetingReminder)) == 6

    # *Next* and the banner: the first round.
    {:ok, sheet} = Core.Leads.get(c.fiza_scope, c.lead.id, @now)
    assert sheet.next.kind == "meeting" and sheet.next.meeting_id == round1.id
    assert sheet.next.words =~ "Meeting · Technical interview · "
    assert sheet.banner.id == round1.id
    assert sheet.tabs.meetings == 2
  end

  test "the clash: the customer's meeting on another lead — named in the team, 'another meeting' elsewhere",
       c do
    {:ok, _first} = Meetings.schedule(c.fiza_scope, c.lead.id, body(c), @now)

    other = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)

    assert {:ok,
            %{
              clash: %{
                words: "Tanweer has Technical interview (Corvid Security) from 14:00 to 15:00."
              }
            }} =
             Meetings.clash(c.fiza_scope, %{
               "lead_id" => other.id,
               "starts_at" => "2026-11-18T09:30:00Z",
               "ends_at" => "2026-11-18T10:30:00Z"
             })

    # Frontend squad serves Tanweer too: Hira scheduling there reads "another meeting"
    # only where she can't see the lead; she leads both, so Farah stands in.
    {:ok, _} = Data.Customers.assign_team(c.tanweer, c.frontend.id, ~D[2026-11-01])
    profile = profile_fixture(Data.Customers.reload(c.tanweer), title: "Frontend")
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    front = lead_fixture(scope_for(farah), team: c.frontend, profile: profile, as: :apply)

    assert {:ok, %{clash: %{words: "Tanweer has another meeting from 14:00 to 15:00."}}} =
             Meetings.clash(scope_for(farah), %{
               "lead_id" => front.id,
               "starts_at" => "2026-11-18T09:00:00Z",
               "ends_at" => "2026-11-18T09:30:00Z"
             })

    # It warns; it never blocks.
    assert {:ok, %{clash: %{words: _}}} =
             Meetings.schedule(scope_for(farah), front.id, body(c, %{"attendees" => []}), @now)

    assert {:ok, %{clash: nil}} =
             Meetings.clash(c.fiza_scope, %{
               "lead_id" => other.id,
               "starts_at" => "2026-11-18T10:00:00Z",
               "ends_at" => "2026-11-18T11:00:00Z"
             })
  end

  test "reschedule, cancel, done, no-show: events, sequence, reminders re-planned; a verb on a cancelled one",
       c do
    {:ok, m} = Meetings.schedule(c.fiza_scope, c.lead.id, body(c), @now)

    {:ok, moved} =
      Meetings.reschedule(
        c.fiza_scope,
        m.id,
        %{"starts_at" => "2026-11-19T13:00:00Z", "ends_at" => "2026-11-19T14:00:00Z"},
        @now
      )

    assert moved.sequence == 1 and moved.starts_at == ~U[2026-11-19 13:00:00.000000Z]

    planned = for j <- all_enqueued(worker: Core.Workers.MeetingReminder), do: j.args["starts_at"]
    assert Enum.uniq(planned) == ["2026-11-19T13:00:00.000000Z"]

    changed =
      Repo.all(Data.Notifications.Notification)
      |> Enum.filter(&(&1.notification_kind_key == "meetings.changed"))

    assert [
             %{
               title: "Technical interview with Corvid Security moved to Thu 19 Nov 18:00 PKT",
               dedupe_key: key
             }
           ] = changed

    assert key == "meeting:#{m.id}:1"

    {:ok, cancelled} =
      Meetings.cancel(c.fiza_scope, m.id, %{"outcome_note" => "Role paused"}, @now)

    assert cancelled.status == :cancelled and cancelled.sequence == 2 and
             cancelled.can.reschedule == false

    assert all_enqueued(worker: Core.Workers.MeetingReminder) == []

    assert Meetings.done(c.fiza_scope, m.id, %{}, @now) ==
             {:error, {:invalid, %{"status" => ["This meeting is already cancelled."]}}}

    {:ok, m2} = Meetings.schedule(c.fiza_scope, c.lead.id, body(c), @now)

    {:ok, _no_show} =
      Meetings.no_show(c.fiza_scope, m2.id, %{"outcome_note" => "They did not join"}, @now)

    labels = for e <- Data.Leads.events(c.lead.id), e.meeting_id, do: {e.kind, e.to_label}
    assert {:meeting_changed, "Thu 19 Nov 14:00 CET"} in labels
    assert {:meeting_cancelled, "Cancelled"} in labels
    assert {:meeting_done, "No-show"} in labels
  end

  test "the ICS: one VEVENT, a stable UID, SEQUENCE, METHOD:PUBLISH; cancelled says so; the customer's too",
       c do
    {:ok, m} = Meetings.schedule(c.fiza_scope, c.lead.id, body(c), @now)
    {:ok, name, ics} = Meetings.ics(c.fiza_scope, m.id)
    assert name == "meeting-#{m.id}.ics"

    for line <- [
          "BEGIN:VCALENDAR",
          "METHOD:PUBLISH",
          "UID:#{m.id}@autoqare",
          "SEQUENCE:0",
          "DTSTART:20261118T090000Z",
          "DTEND:20261118T100000Z",
          "SUMMARY:Technical interview · Corvid Security",
          "LOCATION:https://meet.google.com/abc-defg-hij",
          "STATUS:CONFIRMED"
        ],
        do: assert(ics =~ line <> "\r\n", line)

    {:ok, _} = Meetings.cancel(c.fiza_scope, m.id, %{}, @now)
    {:ok, _name, cancelled} = Meetings.ics(customer_scope_for(c.tanweer), m.id)
    assert cancelled =~ "STATUS:CANCELLED\r\n" and cancelled =~ "SEQUENCE:1\r\n"
    assert cancelled =~ "UID:#{m.id}@autoqare"

    assert Meetings.ics(customer_scope_for(c.naveed), m.id) == {:error, :not_found}
  end

  test "the Meetings page by peer_leads; the customer's own, cut", c do
    {:ok, m} =
      Meetings.schedule(
        c.fiza_scope,
        c.lead.id,
        body(c, %{"notes_md" => "Ask about the on-call"}),
        @now
      )

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})

    assert {:ok, %{items: []}} =
             Meetings.list(scope_for(c.muaz), %{"team_id" => c.backend.id}, @now)

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    assert {:ok, %{items: [%{id: id, can: %{reschedule: false}}]}} =
             Meetings.list(scope_for(c.muaz), %{"team_id" => c.backend.id}, @now)

    assert id == m.id

    assert {:ok,
            %{items: [%{notes_md: nil, clash: nil, can: %{edit: false}, attendees: attendees}]}} =
             Meetings.list(customer_scope_for(c.tanweer), %{}, @now)

    assert [
             %{kind: :user, person: %{name: "Fiza"}},
             %{kind: :customer, person: %{name: "Tanweer"}}
           ] = attendees

    week = %{
      "team_id" => c.backend.id,
      "from" => "2026-11-23T00:00:00Z",
      "to" => "2026-11-30T00:00:00Z"
    }

    assert {:ok, %{items: []}} = Meetings.list(c.fiza_scope, week, @now)

    assert Meetings.schedule(scope_for(c.muaz), c.lead.id, body(c), @now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert {:error, {:invalid, %{"ends_at" => _}}} =
             Meetings.schedule(
               c.fiza_scope,
               c.lead.id,
               body(c, %{"ends_at" => "2026-11-18T08:00:00Z"}),
               @now
             )

    assert {:error, {:invalid, %{"attendees.0" => _}}} =
             Meetings.schedule(
               c.fiza_scope,
               c.lead.id,
               body(c, %{"attendees" => [%{"user_id" => user_fixture().id}]}),
               @now
             )
  end
end
