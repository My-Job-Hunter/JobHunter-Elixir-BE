defmodule Core.ConversationAccessMatrixTest do
  @moduledoc """
  AQ-06 §4, cell by cell: every chair of the cast × five conversations ×
  `read · write · triage` (`Core.Access.Conversations.conversation_actions/0`),
  **three times**, with both teams' `peer_leads` at `hidden`, `view` and
  `edit` — a conversation on leads is seen by whoever reads one of them
  and written by whoever may change one (P4a's rules), a triage item by
  its team. Then the message rows (author or team lead; captured never),
  the customer with `customer_sees_conversations` off, contacts, and the
  same answers through the contexts.

  The conversations: C1 on L1 (Fiza's, Backend, Tanweer), C2 on L2
  (Qasim's, Backend, Tanweer), C3 Backend's triage, C4 on L3 (Hira's,
  Frontend, Imran), C5 another organisation's triage.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Conversations, as: ConversationAccess
  alias Core.Conversations

  @actions ConversationAccess.conversation_actions()
  @full %{ok: @actions}
  @viewer %{ok: [:read, :triage], forbidden: [:write]}
  @customer %{ok: [:read], forbidden: [:write, :triage]}
  @hidden %{not_found: @actions}

  @fixed [
    {:dawud, %{c1: @full, c2: @full, c3: @full, c4: @full, c5: @hidden}},
    {:hira, %{c1: @full, c2: @full, c3: @full, c4: @full, c5: @hidden}},
    {:bilal, %{c1: @full, c2: @full, c3: @full, c4: @hidden, c5: @hidden}},
    {:tanweer, %{c1: @customer, c2: @customer, c3: @hidden, c4: @hidden, c5: @hidden}},
    {:naveed, %{c1: @hidden, c2: @hidden, c3: @hidden, c4: @hidden, c5: @hidden}},
    {:stranger, %{c1: @hidden, c2: @hidden, c3: @hidden, c4: @hidden, c5: @hidden}}
  ]

  @levels [
    hidden: [
      {:fiza, %{c1: @full, c2: @hidden, c3: @full, c4: @hidden, c5: @hidden}},
      {:qasim, %{c1: @hidden, c2: @full, c3: @full, c4: @hidden, c5: @hidden}},
      {:muaz, %{c1: @hidden, c2: @hidden, c3: @full, c4: @hidden, c5: @hidden}},
      {:farah, %{c1: @hidden, c2: @hidden, c3: @hidden, c4: @hidden, c5: @hidden}}
    ],
    view: [
      {:fiza, %{c1: @full, c2: @viewer, c3: @full, c4: @viewer, c5: @hidden}},
      {:qasim, %{c1: @viewer, c2: @full, c3: @full, c4: @hidden, c5: @hidden}},
      {:muaz, %{c1: @viewer, c2: @viewer, c3: @full, c4: @hidden, c5: @hidden}},
      {:farah, %{c1: @hidden, c2: @hidden, c3: @hidden, c4: @viewer, c5: @hidden}}
    ],
    edit: [
      {:fiza, %{c1: @full, c2: @full, c3: @full, c4: @full, c5: @hidden}},
      {:qasim, %{c1: @full, c2: @full, c3: @full, c4: @hidden, c5: @hidden}},
      {:muaz, %{c1: @full, c2: @full, c3: @full, c4: @hidden, c5: @hidden}},
      {:farah, %{c1: @hidden, c2: @hidden, c3: @hidden, c4: @full, c5: @hidden}}
    ]
  ]

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    imran_profile = profile_fixture(c.imran, title: "AI/ML engineer")

    l1 = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
    l2 = lead_fixture(scope_for(c.qasim), team: c.backend, profile: c.golang, state: :in_progress)
    l3 = lead_fixture(scope_for(c.hira), team: c.frontend, profile: imran_profile)

    other = organisation_fixture()
    other_team = team_fixture(other)
    outsider = member_fixture(other_team, :lead)

    conversations = %{
      c1: conversation_fixture(scope_for(c.fiza), lead: l1),
      c2: conversation_fixture(scope_for(c.qasim), lead: l2),
      c3: conversation_fixture(scope_for(c.muaz), team: c.backend),
      c4: conversation_fixture(scope_for(c.hira), lead: l3),
      c5: conversation_fixture(scope_for(outsider), team: other_team)
    }

    scopes = %{
      dawud: scope_for(c.dawud),
      hira: scope_for(c.hira),
      bilal: scope_for(c.bilal),
      fiza: scope_for(c.fiza),
      qasim: scope_for(c.qasim),
      muaz: scope_for(c.muaz),
      farah: scope_for(farah),
      tanweer: customer_scope_for(c.tanweer),
      naveed: customer_scope_for(c.naveed),
      stranger: scope_for(user_fixture())
    }

    Map.merge(c, %{conversations: conversations, scopes: scopes, farah: farah})
  end

  defp put_level(c, level) do
    for team <- [c.backend, c.frontend],
        do: {:ok, _} = Data.Teams.put_settings(team.id, %{peer_leads: level})
  end

  defp rescope(c) do
    Map.new(c.scopes, fn
      {who, %{roles: %{customer_id: id}} = scope} when is_binary(id) -> {who, scope}
      {who, scope} -> {who, scope_for(scope.user)}
    end)
  end

  defp subject(c, key),
    do:
      {:conversation,
       c.conversations
       |> Map.fetch!(key)
       |> Data.Conversations.reload()
       |> Conversations.subject()}

  defp check(c, scopes, who, expected) do
    for {key, cells} <- expected, {outcome, actions} <- cells, action <- actions do
      got = Access.why_not(Map.fetch!(scopes, who), action, subject(c, key))

      assert classify(got) == outcome,
             "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"
    end

    for {_key, cells} <- expected,
        do: assert(Enum.sort(Enum.flat_map(cells, &elem(&1, 1))) == Enum.sort(@actions))
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, {:forbidden, words}}) when is_binary(words), do: :forbidden

  for {who, expected} <- @fixed do
    test "#{who}, whatever the level", c do
      for level <- [:hidden, :view, :edit] do
        put_level(c, level)
        check(c, rescope(c), unquote(who), unquote(Macro.escape(expected)))
      end
    end
  end

  for {level, rows} <- @levels, {who, expected} <- rows do
    test "#{who}, peer_leads #{level}", c do
      put_level(c, unquote(level))
      check(c, rescope(c), unquote(who), unquote(Macro.escape(expected)))
    end
  end

  test "the customer with conversations off: nothing at all", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    check(c, c.scopes, :tanweer, %{c1: @hidden, c2: @hidden, c3: @hidden})
  end

  test "a message: its author or a team lead edits it; a captured one never; a viewer in words",
       c do
    put_level(c, :edit)
    s = rescope(c)
    conv = Data.Conversations.reload(c.conversations.c1)
    typed = message_fixture(s.fiza, conversation: conv)

    captured =
      message_fixture(s.fiza,
        conversation: conv,
        captured_via: :extension,
        contact: contact_fixture(s.fiza)
      )

    note = message_fixture(s.fiza, conversation: conv, is_internal: true)
    csub = Conversations.subject(conv)
    msg = &{:message, Conversations.message_subject(&1, csub)}

    for who <- [:fiza, :hira, :dawud],
        do: assert(Access.why_not(s[who], :edit, msg.(typed)) == :ok)

    assert Access.why_not(s.qasim, :delete, msg.(typed)) ==
             {:error, {:forbidden, "Only its author or a team lead can change this message."}}

    for who <- [:fiza, :hira, :dawud],
        do:
          assert(
            Access.why_not(s[who], :edit, msg.(captured)) ==
              {:error, {:forbidden, "Captured messages can't be edited."}}
          )

    assert Access.why_not(s.farah, :edit, msg.(typed)) == {:error, :not_found}
    assert Access.why_not(s.tanweer, :read, msg.(typed)) == :ok
    assert Access.why_not(s.tanweer, :read, msg.(note)) == {:error, :not_found}
    assert Access.why_not(s.tanweer, :edit, msg.(typed)) == {:error, :not_found}
    assert Access.why_not(s.muaz, :classify, msg.(captured)) == :ok
  end

  test "contacts: every staff member reads and adds; a team lead or the system admin merges; the customer finds none",
       c do
    for who <- [:dawud, :hira, :bilal, :fiza, :muaz, :farah],
        do: assert(Access.why_not(c.scopes[who], :create, {:contact, %{}}) == :ok)

    for who <- [:dawud, :hira, :bilal],
        do:
          assert(
            Access.why_not(c.scopes[who], :merge, {:contact, %{organisation_id: c.org.id}}) == :ok
          )

    assert Access.why_not(c.scopes.muaz, :merge, {:contact, %{organisation_id: c.org.id}}) ==
             {:error, {:forbidden, "Only a team lead can merge contacts."}}

    for who <- [:tanweer, :stranger],
        do: assert(Access.why_not(c.scopes[who], :read, {:contact, %{}}) == {:error, :not_found})
  end

  test "through the contexts: an unseen conversation is 404; the customer's view has no note",
       c do
    put_level(c, :hidden)
    assert Conversations.get(scope_for(c.muaz), c.conversations.c1.id) == {:error, :not_found}
    assert {:ok, %{id: _}} = Conversations.get(scope_for(c.muaz), c.conversations.c3.id)
    assert Conversations.get(scope_for(c.hira), c.conversations.c5.id) == {:error, :not_found}
    assert Conversations.get(c.scopes.tanweer, c.conversations.c3.id) == {:error, :not_found}
  end
end
