defmodule Core.Conversations.InboxTest do
  @moduledoc """
  `POST /eml` (AQ-06 §7.1, §7.2, §13 step 3) with the three made-up files
  of one thread (`priv/eml/thread-{1,2,3}.eml`): uploaded out of order the
  gap shows, then closes when the parent arrives; the same file twice adds
  nothing; a reply to a known message lands on its lead; an unknown
  sender goes to triage; a sender on one open lead links it (likely);
  attachments go through the media allowlist; the HTML is sanitised.
  """

  use Core.CoreCase, async: true

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.{Inbox, Triage}
  alias Core.Media

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    juniper = company_fixture(c.org, name: "Juniper Edge")
    job = job_fixture(fiza, team: c.backend, title: "Platform Engineer", company: juniper)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)
    Map.merge(c, %{fiza_scope: fiza, lead: lead, juniper: juniper})
  end

  defp upload(scope, name, params) do
    media = eml_media(scope, name)
    Inbox.eml(scope, Map.merge(%{"media_id" => media.id}, params), @now)
  end

  # `{body's first line, parent_missing, [children]}`.
  defp shape(nodes),
    do:
      Enum.map(
        nodes,
        &{&1.body_text |> String.split("\n") |> Enum.at(2), &1.parent_missing, shape(&1.children)}
      )

  test "out of order: 1 on the lead, then 3 (a gap), then 2 closes it; the same file twice adds nothing",
       c do
    team = %{"team_id" => c.backend.id}

    assert {:ok, {:created, one}} =
             upload(c.fiza_scope, "thread-1.eml", Map.put(team, "lead_id", c.lead.id))

    assert one.landed == "lead" and one.added == 1 and one.already == 0
    assert [%{id: lead_id}] = one.leads
    assert lead_id == c.lead.id
    [m1] = one.conversation.messages

    assert m1.direction == :in and m1.from.kind == :text and
             m1.from.text == "Mei Chen <mei.chen@juniperedge.example>"

    refute m1.body_html =~ "script"
    assert m1.body_html =~ "<b>Platform Engineer</b>"

    assert {:ok, {:created, three}} = upload(c.fiza_scope, "thread-3.eml", team)
    assert three.landed == "lead" and three.conversation.id == one.conversation.id
    assert three.conversation.gaps == 1

    assert shape(three.conversation.messages) == [
             {"I'm a recruiter at Juniper Edge. We're hiring a Platform Engineer (Go, Kubernetes) for our payments team, fully remote within Asia. Your Golang backend work looks like a close fit — would you be open to a short call this week?",
              false,
              [
                {"Our engineering lead has Thursday 10:00 or Friday 15:00 (Singapore time) free",
                 true, []}
              ]}
           ]

    assert {:ok, {:created, two}} = upload(c.fiza_scope, "thread-2.eml", team)
    assert two.conversation.gaps == 0
    [root] = two.conversation.messages
    [middle] = root.children

    assert [%{filename: "role-summary.txt", content_type: "text/plain", url: "/media/" <> _}] =
             middle.attachments

    assert [%{parent_missing: false, children: []}] = middle.children

    assert {:ok, {:already, again}} = upload(c.fiza_scope, "thread-2.eml", team)
    assert again.added == 0 and again.already == 1

    assert Repo.aggregate(Data.Conversations.Message, :count) == 3
    assert Repo.aggregate(Data.Conversations.Conversation, :count) == 1

    kinds = for e <- Data.Leads.events(c.lead.id), do: e.kind
    assert Enum.count(kinds, &(&1 == :message_in)) == 3
    assert :conversation_linked in kinds
  end

  test "the child first, in triage: its parent arrives and takes it in; the gap closes", c do
    team = %{"team_id" => c.backend.id}

    assert {:ok, {:created, three}} = upload(c.fiza_scope, "thread-3.eml", team)
    assert three.landed == "triage" and three.conversation.gaps == 1

    # The team's leads hear of it; nobody of their own act.
    told =
      Repo.all(Data.Notifications.Notification)
      |> Enum.map(&{&1.user_id, &1.notification_kind_key})

    assert {c.hira.id, "conversations.triage_new"} in told
    assert {c.bilal.id, "conversations.triage_new"} in told

    assert {:ok, {:created, one}} = upload(c.fiza_scope, "thread-1.eml", team)
    assert one.conversation.id == three.conversation.id
    assert [%{children: [%{parent_missing: true}]}] = one.conversation.messages

    assert {:ok, {:created, two}} = upload(c.fiza_scope, "thread-2.eml", team)
    assert two.conversation.gaps == 0
    assert [%{children: [%{children: [%{children: []}]}]}] = two.conversation.messages
  end

  test "a sender who is a contact on one open lead of the team links it (likely); on two, triage with both",
       c do
    mei =
      contact_fixture(c.fiza_scope,
        name: "Mei Chen",
        company: c.juniper,
        handles: [{:email, "mei.chen@juniperedge.example"}]
      )

    {:ok, _} =
      LeadLinks.link(
        c.fiza_scope,
        c.lead.id,
        %{"contact_id" => mei.id, "role" => "recruiter"},
        @now
      )

    assert {:ok, {:created, one}} =
             upload(c.fiza_scope, "thread-1.eml", %{"team_id" => c.backend.id})

    assert one.landed == "lead"
    assert [%{match_method: :sender_handle, confidence: :likely}] = one.conversation.leads
    assert [%{from: %{kind: :contact, contact: %{name: "Mei Chen"}}}] = one.conversation.messages

    other = lead_fixture(c.fiza_scope, team: c.backend, as: :apply)

    {:ok, _} =
      LeadLinks.link(
        c.fiza_scope,
        other.id,
        %{"contact_id" => mei.id, "role" => "recruiter"},
        @now
      )

    Repo.delete_all(Data.Conversations.Conversation)

    assert {:ok, {:created, again}} =
             upload(c.fiza_scope, "thread-1.eml", %{"team_id" => c.backend.id})

    assert again.landed == "triage"

    {:ok, page} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert [%{candidates: candidates, first_message: %{children: []}}] = page.items
    assert Enum.sort(Enum.map(candidates, & &1.lead.id)) == Enum.sort([c.lead.id, other.id])
    assert Enum.all?(candidates, &(&1.why =~ "Mei Chen is a contact on "))
  end

  test "the refusals: another's upload, not an email, another team's lead, a customer", c do
    media = eml_media(c.fiza_scope, "thread-1.eml")

    assert Inbox.eml(
             scope_for(c.qasim),
             %{"media_id" => media.id, "team_id" => c.backend.id},
             @now
           ) ==
             {:error, :not_found}

    frontend_lead = lead_fixture(c.fiza_scope, team: c.frontend)

    assert {:error, {:invalid, %{"lead_id" => _}}} =
             Inbox.eml(
               c.fiza_scope,
               %{
                 "media_id" => media.id,
                 "team_id" => c.backend.id,
                 "lead_id" => frontend_lead.id
               },
               @now
             )

    assert Inbox.eml(
             customer_scope_for(c.tanweer),
             %{"media_id" => media.id, "team_id" => c.backend.id},
             @now
           ) ==
             {:error, :not_found}

    # Bytes that are not an email never become an `eml` row.
    {:ok, row, _target} =
      Media.create(
        c.fiza_scope,
        %{"media_kind" => "eml", "content_type" => "message/rfc822", "byte_count" => 5},
        "/media"
      )

    assert Media.store(c.fiza_scope, row.id, "hello") == {:error, :file_mismatch}
  end
end
