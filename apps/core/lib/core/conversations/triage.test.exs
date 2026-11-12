defmodule Core.Conversations.TriageTest do
  @moduledoc """
  Triage (AQ-06 §7.3, §13 step 5) and *Classify*: derived from the
  conversations on no lead; *Create job and lead* makes a job and a lead
  at *Recruiter contact* in one transaction with the link; *Mark as
  recruiter*; *Ignore* and *Undo*; and each class's move through P4a's own
  verb, with its `classified` event.
  """

  use Core.CoreCase, async: true

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.{Classify, Triage}

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    juniper = company_fixture(c.org, name: "Juniper Edge")

    mei =
      contact_fixture(fiza,
        name: "Mei Chen",
        company: juniper,
        handles: [{:email, "mei.chen@juniperedge.example"}]
      )

    item = conversation_fixture(fiza, team: c.backend, subject: "Platform Engineer role")

    first =
      message_fixture(fiza,
        conversation: item,
        from_kind: :text,
        direction: :in,
        from_text: "Mei Chen <mei.chen@juniperedge.example>",
        sent_at: ~U[2026-11-02 02:15:00.000000Z],
        body_text: "We're hiring a Platform Engineer"
      )

    Map.merge(c, %{fiza_scope: fiza, mei: mei, item: item, first: first, juniper: juniper})
  end

  test "the team's triage: members only; Ignore and Undo; nothing to sort once linked", c do
    assert {:ok, %{items: [%{conversation: %{id: id}, first_message: %{id: first}}]}} =
             Triage.list(scope_for(c.muaz), %{"team_id" => c.backend.id})

    assert id == c.item.id and first == c.first.id
    farah = member_fixture(c.frontend, :member, user_fixture())
    assert Triage.list(scope_for(farah), %{"team_id" => c.backend.id}) == {:error, :not_found}

    assert Triage.list(customer_scope_for(c.tanweer), %{"team_id" => c.backend.id}) ==
             {:error, :not_found}

    assert {:ok, %{ignored_at: %DateTime{}}} = Triage.ignore(scope_for(c.muaz), c.item.id, @now)
    assert {:ok, %{items: []}} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert {:ok, %{ignored_at: nil}} = Triage.unignore(c.fiza_scope, c.item.id, @now)

    lead = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)
    assert {:ok, linked} = Triage.link(c.fiza_scope, c.item.id, %{"lead_id" => lead.id}, @now)
    assert [%{match_method: :by_hand, confidence: :sure}] = linked.leads
    assert {:ok, %{items: []}} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})

    # The link wrote its event and the message's, dated as sent.
    kinds = for e <- Data.Leads.events(lead.id), do: {e.kind, e.visibility}
    assert {:conversation_linked, :staff} in kinds
    assert {:message_in, :customer} in kinds

    assert {:error, {:invalid, %{"id" => _}}} = Triage.ignore(c.fiza_scope, c.item.id, @now)
  end

  test "Create job and lead: a job and a lead at Recruiter contact, linked, in one transaction",
       c do
    body = %{
      "profile_id" => c.golang.id,
      "job" => %{
        "url" => "https://juniperedge.example/careers/platform-engineer",
        "title" => "Platform Engineer",
        "company_id" => c.juniper.id
      }
    }

    assert {:ok, %{lead: card, conversation: conv}} =
             Triage.create_lead(c.fiza_scope, c.item.id, body, @now)

    assert card.state == :in_progress and card.stage.key == "recruiter_contact"
    assert card.job.title == "Platform Engineer"
    assert [%{id: lead_id, match_method: :created_from_triage, confidence: :sure}] = conv.leads
    assert lead_id == card.id

    lead = Data.Leads.get(c.org.id, card.id)
    assert lead.applied_via == :recruiter_inbound
    assert DateTime.compare(lead.applied_at, c.first.sent_at) == :eq

    # The same again: P4a's guard refuses, and nothing half-made is left.
    jobs = Repo.aggregate(Data.Jobs.Job, :count)
    item2 = conversation_fixture(c.fiza_scope, team: c.backend)
    _ = message_fixture(c.fiza_scope, conversation: item2, from_kind: :text, direction: :in)

    assert {:error, {:job_exists, _job}} = Triage.create_lead(c.fiza_scope, item2.id, body, @now)
    assert Repo.aggregate(Data.Jobs.Job, :count) == jobs
    assert Data.Conversations.lead_ids(item2.id) == []
  end

  test "Mark as recruiter: the sender becomes the contact, its messages theirs, the lead's recruiter",
       c do
    lead = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)

    assert {:ok, %{conversation: conv, contact: contact}} =
             Triage.recruiter(
               c.fiza_scope,
               c.item.id,
               %{"contact_id" => c.mei.id, "lead_id" => lead.id},
               @now
             )

    assert contact.id == c.mei.id
    assert [%{from: %{kind: :contact, contact: %{name: "Mei Chen"}}}] = conv.messages
    assert [%{id: _, name: "Mei Chen"}] = conv.participants

    assert [%{contact: %{id: _}, role: :recruiter}] =
             LeadLinks.recruiters(c.fiza_scope, lead.id)

    # Now a candidate, by rule 3.
    {:ok, %{items: [%{candidates: [%{lead: %{id: id}, why: why}]}]}} =
      Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})

    assert id == lead.id and why =~ "Mei Chen is a contact on"

    # A new sender by body: a handle another contact holds is that contact.
    assert {:ok, %{contact: %{id: same}}} =
             Triage.recruiter(
               c.fiza_scope,
               c.item.id,
               %{
                 "contact" => %{
                   "name" => "M. Chen",
                   "handles" => [%{"kind" => "email", "value" => "MEI.CHEN@juniperedge.example"}]
                 }
               },
               @now
             )

    assert same == c.mei.id
  end

  describe "Classify: each class's move through P4a's own verb" do
    setup c do
      lead = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)
      conv = conversation_fixture(c.fiza_scope, lead: lead)

      reply =
        message_fixture(c.fiza_scope, conversation: conv, contact: c.mei, body_text: "Thanks")

      Map.merge(c, %{lead: lead, conv: conv, reply: reply})
    end

    defp classify(c, class, extra \\ %{}),
      do: Classify.run(c.fiza_scope, c.reply.id, Map.put(extra, "class", class), @now)

    defp from(lead), do: %{"state" => "in_progress", "stage" => Data.Leads.reload(lead).stage.key}

    test "interested: to the screening stage; a classified event beside the move's", c do
      assert {:ok, %{lead: sheet, message: %{classification: :interested}, next: nil}} =
               classify(c, "interested")

      assert sheet.stage.key == "recruiter_screen"
      kinds = for e <- Data.Leads.events(c.lead.id), do: e.kind
      assert :classified in kinds and :stage_moved in kinds
    end

    test "rejection: Done · Rejected (from required); position_closed closes the job too", c do
      assert {:error, {:missing, [:from]}} = classify(c, "rejection")

      assert {:ok, %{lead: %{state: :done, outcome: :rejected}}} =
               classify(c, "rejection", %{"from" => from(c.lead)})

      other = lead_fixture(c.fiza_scope, team: c.backend, as: :apply)
      conv = conversation_fixture(c.fiza_scope, lead: other)
      reply = message_fixture(c.fiza_scope, conversation: conv, contact: c.mei)

      assert {:ok, %{lead: %{outcome: :position_closed}}} =
               Classify.run(
                 c.fiza_scope,
                 reply.id,
                 %{"class" => "position_closed", "from" => from(other)},
                 @now
               )

      assert Data.Jobs.reload(Data.Leads.reload(other).job).status == :closed
    end

    test "more_info: a task for the owner on the lead; interview_invitation: schedule the meeting",
         c do
      assert {:ok, %{lead: sheet}} = classify(c, "more_info", %{"due_on" => "2026-11-13"})
      assert [%{title: "Reply to Mei Chen: more information"}] = sheet.tasks

      assert {:ok, %{next: "schedule_meeting", lead: %{state: :in_progress}}} =
               classify(c, "interview_invitation")
    end

    test "unsubscribe: do-not-contact; bounce: the handle invalid; general: the label alone", c do
      assert {:ok, _} = classify(c, "unsubscribe")
      assert Data.Contacts.get(c.org.id, c.mei.id).is_do_not_contact

      out =
        message_fixture(c.fiza_scope,
          conversation: c.conv,
          to_text: "Mei Chen <mei.chen@juniperedge.example>"
        )

      bounce =
        message_fixture(c.fiza_scope,
          conversation: c.conv,
          from_kind: :text,
          direction: :in,
          from_text: "Mail Delivery <mailer-daemon@example.com>",
          parent: out
        )

      assert {:ok, _} = Classify.run(c.fiza_scope, bounce.id, %{"class" => "bounce"}, @now)
      assert [%{is_invalid: true}] = Data.Contacts.get(c.org.id, c.mei.id).handles

      assert {:ok, %{message: %{classification: :general}}} = classify(c, "general")
    end

    test "the refusals: an outbound message, a viewer, a class needing a lead on triage", c do
      out = message_fixture(c.fiza_scope, conversation: c.conv)

      assert {:error, {:invalid, %{"id" => _}}} =
               Classify.run(c.fiza_scope, out.id, %{"class" => "general"}, @now)

      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

      assert Classify.run(scope_for(c.muaz), c.reply.id, %{"class" => "general"}, @now) ==
               {:error,
                {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

      assert {:error, {:invalid, %{"class" => ["needs a lead: link this conversation first"]}}} =
               Classify.run(c.fiza_scope, c.first.id, %{"class" => "interested"}, @now)

      assert {:ok, %{lead: nil}} =
               Classify.run(c.fiza_scope, c.first.id, %{"class" => "general"}, @now)
    end
  end
end
