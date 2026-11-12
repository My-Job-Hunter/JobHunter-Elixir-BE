defmodule Core.Ingest.ConversationTest do
  @moduledoc """
  *Capture conversation* (AQ-06 §9, §13 step 7): a LinkedIn thread with
  Omar Haddad's handle lands on the Corvid lead (rule 3 for the acting
  profile, likely); an unknown sender lands in triage with a new contact;
  a retry adds nothing, by external id or by side and text within a day;
  `side: "us"` is the customer when the page's account is their channel;
  the events are the extension's, with the person.
  """

  use Core.CoreCase, async: true

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.Triage
  alias Core.Ingest.Conversation

  @now ~U[2026-11-11 09:00:00.000000Z]
  @omar "https://www.linkedin.com/in/omar-haddad-example/"

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    ext = %{fiza | via: :extension}
    corvid = company_fixture(c.org, name: "Corvid Security")
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer", company: corvid)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)

    omar =
      contact_fixture(fiza, name: "Omar Haddad", company: corvid, handles: [{:linkedin, @omar}])

    {:ok, _} =
      LeadLinks.link(
        fiza,
        lead.id,
        %{"contact_id" => omar.id, "role" => "hiring_manager"},
        @now
      )

    linkedin =
      channel_fixture(c.tanweer,
        kind: :linkedin,
        handle: "https://www.linkedin.com/in/tanweer-example/"
      )

    Map.merge(c, %{ext: ext, lead: lead, omar: omar, linkedin: linkedin})
  end

  defp capture(c, attrs) do
    fields =
      Map.merge(
        %{
          "captured_at" => "2026-11-11T08:59:00Z",
          "page_kind" => "thread",
          "thread_id" => "2-OWM5ZmFrZS10aHJlYWQ=",
          "other_profile_url" => @omar,
          "other_name" => "Omar Haddad",
          "messages" => [
            %{
              "external_id" => "urn:1",
              "side" => "them",
              "sent_text" => "Nov 3 10:42 AM",
              "text" => "Hi Tanweer, are you open to a backend role?"
            },
            %{
              "external_id" => nil,
              "side" => "us",
              "sent_text" => "11:05 AM",
              "text" => "Yes, happy to talk"
            }
          ]
        },
        attrs[:fields] || %{}
      )

    Conversation.capture(
      c.ext,
      Map.merge(
        %{
          "request_id" => Ecto.UUID.generate(),
          "team_id" => c.backend.id,
          "profile_id" => c.golang.id,
          "url" => "https://www.linkedin.com/messaging/thread/2-OWM5ZmFrZS10aHJlYWQ=/",
          "fields" => fields
        },
        attrs[:params] || %{}
      ),
      @now
    )
  end

  test "Omar's thread lands on the Corvid lead; the events are the extension's; a retry adds nothing",
       c do
    assert {:ok, answer} = capture(c, %{params: %{"identity" => c.linkedin.handle}})
    assert answer.lead_id == c.lead.id and answer.triage == false and answer.added == 2
    assert answer.lead_title == "Backend Developer · Corvid Security"
    assert answer.link_path == "/leads/#{c.lead.id}?team=#{c.backend.id}"

    {:ok, [conv]} = Core.Conversations.for_lead(scope_for(c.fiza), c.lead.id)
    assert conv.platform == :linkedin
    assert [%{match_method: :sender_handle, confidence: :likely}] = conv.leads
    assert conv.channel.id == c.linkedin.id

    assert [
             %{
               direction: :in,
               from: %{kind: :contact},
               sent_at: ~U[2026-11-03 05:42:00.000000Z],
               captured_via: :extension
             },
             %{
               direction: :out,
               from: %{kind: :customer},
               sent_at: ~U[2026-11-03 06:05:00.000000Z]
             }
           ] = conv.messages

    events =
      for e <- Data.Leads.events(c.lead.id),
          e.kind in [:message_in, :message_out],
          do: {e.kind, e.actor_kind}

    assert Enum.sort(events) == [{:message_in, :extension}, {:message_out, :extension}]

    # The same capture again (a new request), and with "Just now" for the second: nothing new.
    assert {:ok, %{added: 0}} = capture(c, %{params: %{"identity" => c.linkedin.handle}})

    again = %{
      "messages" => [
        %{
          "external_id" => "urn:1",
          "side" => "them",
          "sent_text" => "Nov 3 10:42 AM",
          "text" => "Hi Tanweer, are you open to a backend role?"
        },
        %{"side" => "us", "sent_text" => "Nov 3 11:06 AM", "text" => "Yes,  happy to talk"},
        %{
          "external_id" => "urn:3",
          "side" => "them",
          "sent_text" => "Today 9:15 AM",
          "text" => "Great — Tuesday?"
        }
      ]
    }

    assert {:ok, %{added: 1}} = capture(c, %{fields: again})
    assert Repo.aggregate(Data.Conversations.Message, :count) == 3
  end

  test "an unknown sender: a new contact and triage; us is the person pressing without the identity",
       c do
    fields = %{
      "thread_id" => "2-other",
      "other_profile_url" => "https://www.linkedin.com/in/ACoAABcdEfG/",
      "other_name" => "Sam Recruiter",
      "messages" => [
        %{"side" => "them", "sent_text" => "Mon 3:00 PM", "text" => "Hello"},
        %{"side" => "us", "sent_text" => "Mon 3:05 PM", "text" => "Hi"}
      ]
    }

    assert {:ok, answer} = capture(c, %{fields: fields})
    assert answer.triage and answer.lead_id == nil and answer.lead_title == nil
    assert answer.link_path == "/triage?team=#{c.backend.id}"

    contact = Data.Contacts.by_handles(c.org.id, [{:linkedin, "linkedin:acoaabcdefg"}]) |> hd()
    assert contact.name == "Sam Recruiter" and contact.source == :extension

    {:ok, %{items: [item]}} =
      Triage.list(scope_for(c.fiza), %{"team_id" => c.backend.id})

    assert [%{direction: :in}, %{direction: :out, from: %{kind: :user, person: %{name: "Fiza"}}}] =
             flat(item.conversation.messages)

    told =
      Repo.all(Data.Notifications.Notification)
      |> Enum.filter(&(&1.notification_kind_key == "conversations.triage_new"))

    assert Enum.sort(Enum.map(told, & &1.user_id)) ==
             Enum.sort([c.hira.id, c.bilal.id, c.qasim.id])
  end

  test "the refusals: no request id, a thread with no id, a site not ours, another team, a customer",
       c do
    assert {:error, {:missing, [:request_id]}} = capture(c, %{params: %{"request_id" => nil}})

    assert {:error, {:invalid, %{"fields.thread_id" => _}}} =
             capture(c, %{fields: %{"thread_id" => " "}})

    assert {:error, {:invalid, %{"url" => _}}} =
             capture(c, %{params: %{"url" => "https://example.com/x"}})

    farah = member_fixture(c.frontend, :member, user_fixture())

    assert Conversation.capture(
             %{scope_for(farah) | via: :extension},
             %{
               "request_id" => Ecto.UUID.generate(),
               "team_id" => c.backend.id,
               "profile_id" => c.golang.id,
               "url" => "https://www.linkedin.com/messaging/thread/x/",
               "fields" => %{}
             },
             @now
           ) == {:error, :not_found}

    assert {:error, :not_found} =
             Conversation.capture(
               customer_scope_for(c.tanweer),
               %{"request_id" => Ecto.UUID.generate()},
               @now
             )
  end

  defp flat(nodes), do: Enum.flat_map(nodes, &[&1 | flat(&1.children)])
end
