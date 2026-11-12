defmodule Core.Conversations.MessagesTest do
  @moduledoc """
  *Log message* (AQ-06 §7.1, §13 step 2): a five-message email thread
  copied by hand with *Replies to* keeps the original's tree (two
  branches); a staff note is in it and the customer never reads it; each
  message writes `message_in` / `message_out` on the lead (the customer's
  when the team allows conversations), an inbound one tells the owner and
  clears *Follow-up due*; hand-typed messages are edited and deleted by
  their author or a team lead, captured ones never.
  """

  use Core.CoreCase, async: true

  alias Core.Conversations
  alias Core.Conversations.Messages
  alias Core.Leads.FollowUp

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)

    lead =
      lead_fixture(fiza,
        team: c.backend,
        profile: c.golang,
        as: :apply,
        applied_at: ~U[2026-11-01 09:00:00.000000Z]
      )

    company = company_fixture(c.org, name: "Corvid Security")

    omar =
      contact_fixture(fiza,
        name: "Omar Haddad",
        company: company,
        handles: [{:email, "omar.haddad@corvid.example"}]
      )

    Map.merge(c, %{lead: lead, omar: omar, fiza_scope: fiza})
  end

  defp at(day, hour),
    do:
      DateTime.new!(Date.new!(2026, 11, day), Time.new!(hour, 0, 0), "Etc/UTC")
      |> DateTime.to_iso8601()

  defp log(scope, params), do: Messages.create(scope, params, @now)

  # The tree as nested `{body, [children]}`.
  defp shape(nodes), do: Enum.map(nodes, &{&1.body_text, shape(&1.children)})

  test "a hand-copied thread's tree equals the original's: two branches, a note in it", c do
    s = c.fiza_scope

    {:ok, conv} =
      log(s, %{
        "lead_id" => c.lead.id,
        "platform" => "email",
        "subject" => "Backend role at Corvid",
        "direction" => "in",
        "from" => %{"kind" => "contact", "contact_id" => c.omar.id},
        "sent_at" => at(2, 9),
        "body_md" => "1 · Omar: are you open to a backend role?"
      })

    [m1] = conv.messages

    reply = fn from, parent, body, sent ->
      {:ok, v} =
        log(s, %{
          "conversation_id" => conv.id,
          "direction" => if(from["kind"] == "contact", do: "in", else: "out"),
          "from" => from,
          "sent_at" => sent,
          "body_md" => body,
          "parent_message_id" => parent
        })

      v
    end

    v = reply.(%{"kind" => "customer"}, m1.id, "2 · Tanweer: yes, tell me more", at(2, 12))
    m2 = v.messages |> hd() |> Map.get(:children) |> Enum.find(&(&1.body_text =~ "2 ·"))
    v = reply.(%{"kind" => "user"}, m1.id, "3 · Fiza: Tanweer's CV attached", at(2, 13))
    m3 = v.messages |> hd() |> Map.get(:children) |> Enum.find(&(&1.body_text =~ "3 ·"))

    v =
      reply.(
        %{"kind" => "contact", "contact_id" => c.omar.id},
        m2.id,
        "4 · Omar: great, a call Tuesday?",
        at(3, 9)
      )

    m4 = v.messages |> hd() |> Map.get(:children) |> hd() |> Map.get(:children) |> hd()

    _v =
      reply.(
        %{"kind" => "contact", "contact_id" => c.omar.id},
        m3.id,
        "5 · Omar: got the CV",
        at(3, 10)
      )

    {:ok, noted} =
      log(s, %{
        "conversation_id" => conv.id,
        "is_internal" => true,
        "sent_at" => at(3, 11),
        "body_md" => "Note: Omar is the hiring manager",
        "parent_message_id" => m4.id
      })

    assert shape(noted.messages) == [
             {"1 · Omar: are you open to a backend role?",
              [
                {"2 · Tanweer: yes, tell me more",
                 [
                   {"4 · Omar: great, a call Tuesday?",
                    [{"Note: Omar is the hiring manager", []}]}
                 ]},
                {"3 · Fiza: Tanweer's CV attached", [{"5 · Omar: got the CV", []}]}
              ]}
           ]

    assert noted.gaps == 0

    assert [%{id: _, title: _, match_method: :by_hand, confidence: :sure}] =
             noted.leads

    # The events: five, the note none; the customer's (the team allows conversations).
    kinds =
      for e <- Data.Leads.events(c.lead.id),
          e.kind in [:message_in, :message_out],
          do: {e.kind, e.visibility}

    assert Enum.sort(kinds) ==
             Enum.sort([
               {:message_in, :customer},
               {:message_in, :customer},
               {:message_in, :customer},
               {:message_out, :customer},
               {:message_out, :customer}
             ])

    # Tanweer's portal: the thread without the note, no addresses, staff names as the team shows them.
    {:ok, [portal]} = Conversations.for_lead(customer_scope_for(c.tanweer), c.lead.id)

    assert shape(portal.messages) == [
             {"1 · Omar: are you open to a backend role?",
              [
                {"2 · Tanweer: yes, tell me more", [{"4 · Omar: great, a call Tuesday?", []}]},
                {"3 · Fiza: Tanweer's CV attached", [{"5 · Omar: got the CV", []}]}
              ]}
           ]

    # The team hides conversations: none.
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    {:ok, sheet} = Core.Leads.get(customer_scope_for(c.tanweer), c.lead.id, @now)
    assert sheet.conversations == nil
    assert Conversations.for_lead(customer_scope_for(c.tanweer), c.lead.id) |> elem(1) == []
  end

  test "an inbound message tells the owner and clears Follow-up due", c do
    s = scope_for(c.qasim)
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})
    s = scope_for(s.user)

    # Day 5 after applying: a follow-up is due.
    day5 = ~U[2026-11-06 10:00:00.000000Z]
    assert {:ok, %{follow_up: %{state: :due}}} = Core.Leads.get(c.fiza_scope, c.lead.id, day5)

    {:ok, _conv} =
      Messages.create(
        s,
        %{
          "lead_id" => c.lead.id,
          "direction" => "in",
          "from" => %{"kind" => "contact", "contact_id" => c.omar.id},
          "sent_at" => "2026-11-05T10:00:00Z",
          "body_md" => "Thanks, we'll be in touch"
        },
        day5
      )

    assert {:ok, %{follow_up: %{state: :none}}} = Core.Leads.get(c.fiza_scope, c.lead.id, day5)
    assert FollowUp.scan(day5) |> is_map()

    assert [
             %{
               notification_kind_key: "conversations.reply_received",
               title: "Omar Haddad replied on " <> _
             }
           ] =
             Repo.all(Data.Notifications.Notification) |> Enum.filter(&(&1.user_id == c.fiza.id))
  end

  test "edit and delete: its author or a team lead; a captured message never; a tombstone keeps its place",
       c do
    conv = conversation_fixture(c.fiza_scope, lead: c.lead)
    mine = message_fixture(c.fiza_scope, conversation: conv, body_text: "Typo hre")

    captured =
      message_fixture(c.fiza_scope,
        conversation: conv,
        contact: c.omar,
        captured_via: :eml_upload,
        parent: mine
      )

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})

    assert Messages.update(scope_for(c.qasim), mine.id, %{"body_md" => "x"}, @now) ==
             {:error, {:forbidden, "Only its author or a team lead can change this message."}}

    assert Messages.update(scope_for(c.hira), captured.id, %{"body_md" => "x"}, @now) ==
             {:error, {:forbidden, "Captured messages can't be edited."}}

    assert {:ok, edited} =
             Messages.update(c.fiza_scope, mine.id, %{"body_md" => "Typo here"}, @now)

    assert [%{body_text: "Typo here", can: %{edit: true}, children: [%{id: id}]}] =
             edited.messages

    assert id == captured.id

    assert :ok = Messages.delete(scope_for(c.hira), mine.id, @now)
    {:ok, after_delete} = Conversations.get(c.fiza_scope, conv.id)

    assert [%{deleted: true, body_text: nil, can: %{edit: false}, children: [_child]}] =
             after_delete.messages

    assert Messages.update(c.fiza_scope, mine.id, %{"body_md" => "back"}, @now) ==
             {:error, {:invalid, %{"id" => ["is a deleted message"]}}}

    # Audited, both.
    actions =
      Repo.all(Data.Audit.AuditEvent)
      |> Enum.filter(&(&1.subject_kind == "messages"))
      |> Enum.map(& &1.action)

    assert "updated" in actions and "deleted" in actions
  end

  test "the refusals: a viewer, *Replies to* elsewhere, the future, a customer kind with no customer",
       c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})
    muaz = scope_for(c.muaz)

    base = %{
      "lead_id" => c.lead.id,
      "direction" => "out",
      "from" => %{"kind" => "user"},
      "sent_at" => "2026-11-10T10:00:00Z",
      "body_md" => "Hello"
    }

    assert log(muaz, base) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert {:error, {:invalid, %{"sent_at" => ["can't be in the future"]}}} =
             log(c.fiza_scope, %{base | "sent_at" => "2026-12-01T10:00:00Z"})

    other = conversation_fixture(c.fiza_scope, team: c.backend)
    stray = message_fixture(c.fiza_scope, conversation: other)

    assert {:error, {:invalid, %{"parent_message_id" => _}}} =
             log(c.fiza_scope, Map.put(base, "parent_message_id", stray.id))

    assert {:error, {:invalid, %{"from.kind" => _}}} =
             log(c.fiza_scope, %{
               "team_id" => c.backend.id,
               "direction" => "out",
               "from" => %{"kind" => "customer"},
               "sent_at" => "2026-11-10T10:00:00Z",
               "body_md" => "Hi"
             })

    assert log(customer_scope_for(c.tanweer), base) ==
             {:error, {:forbidden, "That is for the team serving you to do."}}
  end
end
