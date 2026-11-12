defmodule Core.ContactsTest do
  @moduledoc """
  Contacts (AQ-06 §6, §13 step 1): the match check — *exact* on a handle,
  *possible* on the same name and company, else *new*; *New contact*
  re-runs it (409 `contact_exists` for a handle another contact holds);
  the list by keyset; a merge keeps every link and is a team lead's; a
  lead's contacts with their events; the customer finds none.
  """

  use Core.CoreCase, async: true

  alias Core.Contacts
  alias Core.Contacts.LeadLinks

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    juniper = company_fixture(c.org, name: "Juniper Edge")

    {:ok, {:created, mei}} =
      Contacts.create(
        fiza,
        %{
          "name" => "Mei Chen",
          "title" => "Talent Partner",
          "company_id" => juniper.id,
          "time_zone" => "Asia/Singapore",
          "handles" => [
            %{"kind" => "email", "value" => "mei.chen@juniperedge.example"},
            %{"kind" => "linkedin", "value" => "https://www.linkedin.com/in/mei-chen-example/"}
          ]
        },
        @now
      )

    Map.merge(c, %{fiza_scope: fiza, juniper: juniper, mei: mei})
  end

  test "the match: exact on a handle (any spelling), possible on name and company, else new", c do
    exact = %{
      "name" => "Mei",
      "handles" => [%{"kind" => "email", "value" => " MEI.CHEN@JuniperEdge.example "}]
    }

    assert {:ok, %{answer: :exact, contact: %{id: id}, candidates: []}} =
             Contacts.match(c.fiza_scope, exact)

    assert id == c.mei.id

    linkedin = %{
      "name" => "x",
      "handles" => [%{"kind" => "linkedin", "value" => "linkedin.com/in/Mei-Chen-Example?trk=1"}]
    }

    assert {:ok, %{answer: :exact}} = Contacts.match(c.fiza_scope, linkedin)

    assert {:ok, %{answer: :possible, contact: nil, candidates: [%{name: "Mei Chen"}]}} =
             Contacts.match(c.fiza_scope, %{
               "name" => "Mei Chen",
               "company_name" => "juniper edge",
               "handles" => []
             })

    # Trigram ≥ 0.8 with the same company: "Mei-Chen"; a typo below it is new.
    assert {:ok, %{answer: :possible}} =
             Contacts.match(c.fiza_scope, %{"name" => "Mei-Chen", "company_id" => c.juniper.id})

    assert {:ok, %{answer: :new}} =
             Contacts.match(c.fiza_scope, %{"name" => "Mei Chenn", "company_id" => c.juniper.id})

    corvid = company_fixture(c.org, name: "Corvid Security")

    assert {:ok, %{answer: :new, candidates: []}} =
             Contacts.match(c.fiza_scope, %{"name" => "Mei Chen", "company_id" => corvid.id})

    assert {:ok, %{answer: :new}} = Contacts.match(c.fiza_scope, %{"name" => "Omar Haddad"})
  end

  test "New contact: 409 contact_exists for a held handle; use_possible uses the match; the page's shape",
       c do
    assert Contacts.create(
             c.fiza_scope,
             %{
               "name" => "Someone",
               "handles" => [
                 %{"kind" => "linkedin", "value" => "https://linkedin.com/in/mei-chen-example"}
               ]
             },
             @now
           ) ==
             {:error,
              {:contact_exists, %{contact_id: c.mei.id, name: "Mei Chen", kind: :linkedin}}}

    body = %{
      "name" => "Mei Chen",
      "company_id" => c.juniper.id,
      "use_possible" => true,
      "handles" => [%{"kind" => "phone", "value" => "+65 6123 4567"}]
    }

    assert {:ok, {:used, used}} = Contacts.create(c.fiza_scope, body, @now)
    assert used.id == c.mei.id
    assert Enum.map(used.handles, & &1.kind) == [:email, :linkedin, :phone]

    assert {:ok, {:created, other}} =
             Contacts.create(c.fiza_scope, Map.drop(body, ["use_possible", "handles"]), @now)

    refute other.id == c.mei.id

    assert {:error, {:invalid, %{"handles.0" => ["is not a LinkedIn profile link"]}}} =
             Contacts.create(
               c.fiza_scope,
               %{"name" => "X", "handles" => [%{"kind" => "linkedin", "value" => "nope"}]},
               @now
             )

    assert c.mei.company == %{id: c.juniper.id, name: "Juniper Edge"}
    assert c.mei.can == %{edit: true, merge: false}
    assert Contacts.get(customer_scope_for(c.tanweer), c.mei.id) == {:error, :not_found}
  end

  test "the list: by name, by keyset, searched by name or handle", c do
    for n <- 1..3, do: Contacts.create(c.fiza_scope, %{"name" => "Zed #{n}"}, @now)

    assert {:ok, %{items: items, next_cursor: nil}} = Contacts.list(c.fiza_scope, %{})
    assert Enum.map(items, & &1.name) == ["Mei Chen", "Zed 1", "Zed 2", "Zed 3"]
    assert hd(items).leads_count == 0

    assert {:ok, %{items: [%{name: "Mei Chen"}]}} =
             Contacts.list(c.fiza_scope, %{"q" => "juniperedge"})

    assert {:ok, %{items: [_, _, _]}} = Contacts.list(c.fiza_scope, %{"q" => "zed"})

    assert {:error, {:invalid, %{"cursor" => _}}} =
             Contacts.list(c.fiza_scope, %{"cursor" => "nope"})
  end

  test "merge: every link moves to the survivor; the merged row stays; a team lead's alone", c do
    lead = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)

    {:ok, {:created, dup}} =
      Contacts.create(
        c.fiza_scope,
        %{
          "name" => "M. Chen",
          "handles" => [%{"kind" => "email", "value" => "mei@personal.example"}]
        },
        @now
      )

    dup = Data.Contacts.get(c.org.id, dup.id)

    {:ok, _} =
      LeadLinks.link(
        c.fiza_scope,
        lead.id,
        %{"contact_id" => dup.id, "role" => "recruiter"},
        @now
      )

    conv = conversation_fixture(c.fiza_scope, lead: lead)
    message = message_fixture(c.fiza_scope, conversation: conv, contact: dup)
    meeting = meeting_fixture(c.fiza_scope, lead: lead, attendees: [{:contact, dup}])

    assert Contacts.merge(scope_for(c.muaz), dup.id, %{"into_contact_id" => c.mei.id}, @now) ==
             {:error, {:forbidden, "Only a team lead can merge contacts."}}

    assert {:ok, survivor} =
             Contacts.merge(scope_for(c.hira), dup.id, %{"into_contact_id" => c.mei.id}, @now)

    assert survivor.id == c.mei.id
    assert "mei@personal.example" in Enum.map(survivor.handles, & &1.value)
    assert [%{id: lead_id, role: :recruiter}] = survivor.leads
    assert lead_id == lead.id

    assert Repo.get_by(Data.Conversations.Participant,
             conversation_id: conv.id,
             contact_id: c.mei.id
           )

    assert Repo.get!(Data.Conversations.Message, message.id).from_contact_id == c.mei.id
    assert [%{contact_id: mei_id}] = Data.Meetings.get(c.org.id, meeting.id).attendees
    assert mei_id == c.mei.id

    merged = Data.Contacts.get(c.org.id, dup.id)
    assert merged.merged_into_contact_id == c.mei.id

    assert [%{from_name: "M. Chen", from_handles: ["email: mei@personal.example"]}] =
             Data.Contacts.merges_into(c.mei.id)

    # A merged contact answers the match as its survivor, and merges no more.
    assert {:ok, %{answer: :exact, contact: %{id: ^mei_id}}} =
             Contacts.match(c.fiza_scope, %{
               "handles" => [%{"kind" => "email", "value" => "mei@personal.example"}]
             })

    assert {:error, {:invalid, %{"id" => _}}} =
             Contacts.merge(scope_for(c.hira), dup.id, %{"into_contact_id" => c.mei.id}, @now)
  end

  test "a lead's contacts: link and unlink, staff-only events; a viewer refused in P4a's words",
       c do
    lead = lead_fixture(c.fiza_scope, team: c.backend, profile: c.golang, as: :apply)

    assert {:ok, [%{contact: %{name: "Mei Chen"}, role: :recruiter}]} =
             LeadLinks.link(
               c.fiza_scope,
               lead.id,
               %{"contact_id" => c.mei.id, "role" => "recruiter"},
               @now
             )

    {:ok, sheet} = Core.Leads.get(c.fiza_scope, lead.id, @now)
    assert [%{contact: %{id: _, leads_count: 1}, role: :recruiter}] = sheet.recruiters

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    assert LeadLinks.unlink(scope_for(c.muaz), lead.id, c.mei.id, @now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert :ok = LeadLinks.unlink(c.fiza_scope, lead.id, c.mei.id, @now)

    events =
      for e <- Data.Leads.events(lead.id),
          e.kind in [:contact_linked, :contact_unlinked],
          do: {e.kind, e.visibility, e.to_label || e.from_label}

    assert Enum.sort(events) ==
             [
               {:contact_linked, :staff, "Mei Chen · Recruiter"},
               {:contact_unlinked, :staff, "Mei Chen · Recruiter"}
             ]

    {:ok, portal} = Core.Leads.get(customer_scope_for(c.tanweer), lead.id, @now)
    refute Enum.any?(portal.events, &(&1.kind in [:contact_linked, :contact_unlinked]))
  end

  test "edit and handles: audited; a handle another holds is the 409; removed", c do
    assert {:ok, %{title: "Senior Talent Partner"}} =
             Contacts.update(c.fiza_scope, c.mei.id, %{"title" => "Senior Talent Partner"}, @now)

    {:ok, {:created, omar}} = Contacts.create(c.fiza_scope, %{"name" => "Omar Haddad"}, @now)

    assert Contacts.add_handle(
             c.fiza_scope,
             omar.id,
             %{"kind" => "email", "value" => "mei.chen@juniperedge.example"},
             @now
           ) ==
             {:error, {:contact_exists, %{contact_id: c.mei.id, name: "Mei Chen", kind: :email}}}

    assert {:ok, %{handles: [%{id: handle_id, value: "omar.haddad@corvid.example"}]}} =
             Contacts.add_handle(
               c.fiza_scope,
               omar.id,
               %{"kind" => "email", "value" => "omar.haddad@corvid.example"},
               @now
             )

    assert :ok = Contacts.remove_handle(c.fiza_scope, handle_id, @now)
    assert Data.Contacts.get(c.org.id, omar.id).handles == []

    kinds = Repo.all(Data.Audit.AuditEvent) |> Enum.map(&{&1.subject_kind, &1.action})
    assert {"contacts", "updated"} in kinds and {"contact_handles", "deleted"} in kinds
  end
end
