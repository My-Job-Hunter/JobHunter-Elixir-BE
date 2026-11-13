defmodule Core.Meetings.ProposalsTest do
  @moduledoc """
  AQ-09 §9 and §11.4, the invitation's life (`priv/eml/invite-*.eml`):
  a `REQUEST` on a matched lead proposes a meeting (no reminders, the
  owner told, the customer never sees it); *Confirm* schedules it with
  P6's reminders and notices; `SEQUENCE 1` proposes the move, confirmed;
  `CANCEL` proposes the cancel, dismissed; a proposed meeting dismissed is
  gone; an invitation in triage proposes when it's linked; 409
  `meeting_not_proposed`; who may confirm.
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Contacts.LeadLinks
  alias Core.Conversations
  alias Core.Conversations.Triage
  alias Core.Inbound
  alias Core.Meetings
  alias Core.Meetings.Proposals
  alias Core.Workers.MeetingReminder
  alias Data.Scope

  @now ~U[2026-11-12 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    channel = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    corvid = company_fixture(c.org, name: "Corvid Security")
    job = job_fixture(fiza, team: c.backend, title: "Senior Golang Engineer", company: corvid)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)

    omar =
      contact_fixture(fiza,
        name: "Omar Haddad",
        company: corvid,
        handles: [{:email, "omar.haddad@corvid.example"}]
      )

    Map.merge(c, %{
      fiza_scope: fiza,
      channel: Data.Channels.reload(channel),
      lead: lead,
      omar: omar
    })
  end

  defp deliver(c, name) do
    text = File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__))

    {:ok, answer} =
      Inbound.dev(
        Scope.system(),
        %{"to" => Inbound.address(c.channel.inbound_token), "eml" => text},
        @now
      )

    answer
  end

  defp on_lead(c),
    do:
      {:ok, _} =
        LeadLinks.link(
          c.fiza_scope,
          c.lead.id,
          %{"contact_id" => c.omar.id, "role" => "interviewer"},
          @now
        )

  defp only_meeting(c) do
    {:ok, [m]} = Meetings.for_lead(c.fiza_scope, c.lead.id, @now)
    m
  end

  defp told(kind),
    do:
      for(n <- Repo.all(Data.Notifications.Notification), n.notification_kind_key == kind, do: n)

  test "REQUEST proposes, Confirm schedules, SEQUENCE 1 proposes the move, Confirm moves it, CANCEL proposes the cancel, Dismiss drops it",
       c do
    on_lead(c)

    %{outcome: :landed, message_id: message_id, conversation_id: cid} =
      deliver(c, "invite-request.eml")

    m = only_meeting(c)
    assert m.status == :proposed and m.source == :email_invite
    assert m.title == "Technical interview" and m.meeting_kind == :technical

    assert m.starts_at == ~U[2026-11-18 09:00:00.000000Z] and
             m.ends_at == ~U[2026-11-18 10:00:00.000000Z]

    assert m.time_zone == "Asia/Karachi" and m.platform == :google_meet
    assert m.join_url == "https://meet.google.com/abc-defg-hij"
    assert m.proposal == %{organizer: "Omar Haddad", method: "REQUEST", sequence: 0, change: nil}
    assert m.from_message.id == message_id and m.from_message.conversation_id == cid
    assert m.from_message.subject == "Invitation: Technical interview @ Wed 18 Nov 14:00 PKT"
    assert Enum.sort(Enum.map(m.attendees, & &1.kind)) == [:contact, :customer]

    # No reminders, no meetings.scheduled; the owner told.
    assert all_enqueued(worker: MeetingReminder) == []
    assert told("meetings.scheduled") == []

    assert [%{user_id: owner, title: title}] = told("meetings.proposed")
    assert owner == c.fiza.id

    assert title ==
             "Corvid Security sent an invitation: Technical interview, Wed 18 Nov 14:00 PKT. Confirm it?"

    # The message names the meeting it made.
    {:ok, conversation} = Conversations.get(c.fiza_scope, cid)
    assert [%{invite: %{meeting_id: meeting_id}}] = conversation.messages
    assert meeting_id == m.id

    # The customer never sees a proposed meeting.
    tanweer = customer_scope_for(c.tanweer)
    assert Meetings.get(tanweer, m.id) == {:error, :not_found}
    assert {:ok, []} = Meetings.for_lead(tanweer, c.lead.id, @now)
    assert {:ok, %{items: []}} = Meetings.list(tanweer, %{}, @now)
    assert Proposals.confirm(tanweer, m.id, @now) == {:error, :not_found}

    # The same mail again changes nothing.
    assert %{outcome: :duplicate} = deliver(c, "invite-request.eml")

    # Confirm: scheduled, reminders planned, everyone told.
    assert {:ok, confirmed} = Proposals.confirm(c.fiza_scope, m.id, @now)
    assert confirmed.status == :scheduled
    assert length(all_enqueued(worker: MeetingReminder)) == 3
    assert Enum.map(told("meetings.scheduled"), & &1.user_id) == [c.tanweer.user_id]
    assert {:ok, %{status: :scheduled}} = Meetings.get(tanweer, m.id)

    assert Proposals.confirm(c.fiza_scope, m.id, @now) ==
             {:error, {:meeting_not_proposed, Data.Meetings.get(c.org.id, m.id)}}

    # SEQUENCE 1: the move proposed on the confirmed meeting.
    deliver(c, "invite-sequence-1.eml")
    moved = only_meeting(c)
    assert moved.status == :scheduled and moved.starts_at == ~U[2026-11-18 09:00:00.000000Z]

    assert moved.proposal.change == %{
             starts_at: ~U[2026-11-19 10:00:00Z],
             ends_at: ~U[2026-11-19 11:00:00Z],
             cancel: false
           }

    assert Enum.any?(
             told("meetings.proposed"),
             &(&1.title ==
                 "Corvid Security moved Technical interview to Thu 19 Nov 15:00 PKT. Accept the change?")
           )

    assert {:ok, applied} = Proposals.confirm(c.fiza_scope, m.id, @now)
    assert applied.starts_at == ~U[2026-11-19 10:00:00.000000Z] and applied.sequence == 1
    assert applied.proposal.change == nil and applied.proposal.sequence == 1

    # CANCEL: the cancel proposed, then dismissed; the meeting stays.
    deliver(c, "invite-cancel.eml")

    assert %{status: :scheduled, proposal: %{method: "CANCEL", change: %{cancel: true}}} =
             only_meeting(c)

    assert Proposals.dismiss(c.fiza_scope, m.id, @now) == {:ok, :dismissed}
    assert %{status: :scheduled, proposal: %{change: nil}} = only_meeting(c)
    assert {:error, {:meeting_not_proposed, _}} = Proposals.dismiss(c.fiza_scope, m.id, @now)
  end

  test "a confirmed cancel cancels; a proposed meeting dismissed is gone", c do
    on_lead(c)
    deliver(c, "invite-request.eml")
    m = only_meeting(c)
    {:ok, _} = Proposals.confirm(c.fiza_scope, m.id, @now)
    deliver(c, "invite-cancel.eml")
    assert {:ok, %{status: :cancelled}} = Proposals.confirm(c.fiza_scope, m.id, @now)

    Repo.delete_all(Data.Meetings.Meeting)
    Repo.delete_all(Data.Conversations.Conversation)
    Repo.delete_all(Data.Inbound.InboundMessage)
    deliver(c, "invite-request.eml")
    m = only_meeting(c)
    assert Proposals.dismiss(c.fiza_scope, m.id, @now) == {:ok, :dismissed}
    assert {:ok, []} = Meetings.for_lead(c.fiza_scope, c.lead.id, @now)
  end

  test "an invitation from a stranger waits in triage, and proposes when it's linked", c do
    %{conversation_id: cid} = deliver(c, "invite-request.eml")
    assert {:ok, []} = Meetings.for_lead(c.fiza_scope, c.lead.id, @now)

    assert {:ok, _} = Triage.link(c.fiza_scope, cid, %{"lead_id" => c.lead.id}, @now)
    assert %{status: :proposed, proposal: %{sequence: 0}} = only_meeting(c)

    # Omar marked a contact on the lead, his update lands there and updates the proposal in place.
    on_lead(c)
    deliver(c, "invite-sequence-1.eml")

    assert %{
             status: :proposed,
             starts_at: ~U[2026-11-19 10:00:00.000000Z],
             proposal: %{sequence: 1, change: nil}
           } =
             only_meeting(c)
  end

  test "who may confirm: whoever may change the lead's meetings (P6), and a verb on a proposed meeting waits for it",
       c do
    on_lead(c)
    deliver(c, "invite-request.eml")
    m = only_meeting(c)

    Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    assert Proposals.confirm(scope_for(c.muaz), m.id, @now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert {:error,
            {:invalid, %{"status" => ["This meeting is only proposed: confirm it first."]}}} =
             Meetings.cancel(c.fiza_scope, m.id, %{}, @now)

    assert {:ok, %{status: :scheduled}} = Proposals.confirm(scope_for(c.hira), m.id, @now)
  end
end
