defmodule Core.MeetingAccessMatrixTest do
  @moduledoc """
  AQ-06 §4, cell by cell: every chair × four meetings × every meeting
  action (`Core.Access.Conversations.meeting_actions/0`), **three times**,
  with both teams' `peer_leads` at `hidden`, `view` and `edit` — a meeting
  is read with its lead and changed by whoever may change the lead (P4a's
  words at `view`); the customer reads their own, always, and changes
  nothing. Then the same answers through `Core.Meetings`.

  The meetings: M1 on L1 (Fiza's, Backend, Tanweer), M2 on L2 (Qasim's,
  Backend, Tanweer), M3 on L3 (Hira's, Frontend, Imran), M4 another
  organisation's.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Conversations, as: ConversationAccess
  alias Core.Meetings

  @actions ConversationAccess.meeting_actions()
  @writes @actions -- [:read]
  @full %{ok: @actions}
  @viewer %{ok: [:read], forbidden: @writes}
  @hidden %{not_found: @actions}

  @fixed [
    {:dawud, %{m1: @full, m2: @full, m3: @full, m4: @hidden}},
    {:hira, %{m1: @full, m2: @full, m3: @full, m4: @hidden}},
    {:bilal, %{m1: @full, m2: @full, m3: @hidden, m4: @hidden}},
    {:tanweer, %{m1: @viewer, m2: @viewer, m3: @hidden, m4: @hidden}},
    {:naveed, %{m1: @hidden, m2: @hidden, m3: @hidden, m4: @hidden}},
    {:stranger, %{m1: @hidden, m2: @hidden, m3: @hidden, m4: @hidden}}
  ]

  @levels [
    hidden: [
      {:fiza, %{m1: @full, m2: @hidden, m3: @hidden, m4: @hidden}},
      {:qasim, %{m1: @hidden, m2: @full, m3: @hidden, m4: @hidden}},
      {:muaz, %{m1: @hidden, m2: @hidden, m3: @hidden, m4: @hidden}},
      {:farah, %{m1: @hidden, m2: @hidden, m3: @hidden, m4: @hidden}}
    ],
    view: [
      {:fiza, %{m1: @full, m2: @viewer, m3: @viewer, m4: @hidden}},
      {:qasim, %{m1: @viewer, m2: @full, m3: @hidden, m4: @hidden}},
      {:muaz, %{m1: @viewer, m2: @viewer, m3: @hidden, m4: @hidden}},
      {:farah, %{m1: @hidden, m2: @hidden, m3: @viewer, m4: @hidden}}
    ],
    edit: [
      {:fiza, %{m1: @full, m2: @full, m3: @full, m4: @hidden}},
      {:qasim, %{m1: @full, m2: @full, m3: @hidden, m4: @hidden}},
      {:muaz, %{m1: @full, m2: @full, m3: @hidden, m4: @hidden}},
      {:farah, %{m1: @hidden, m2: @hidden, m3: @full, m4: @hidden}}
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
    l4 = lead_fixture(scope_for(outsider), team: other_team)

    meetings =
      for {key, scope, lead} <- [
            {:m1, scope_for(c.fiza), l1},
            {:m2, scope_for(c.qasim), l2},
            {:m3, scope_for(c.hira), l3},
            {:m4, scope_for(outsider), l4}
          ],
          into: %{},
          do: {key, meeting_fixture(scope, lead: Data.Leads.reload(lead))}

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

    Map.merge(c, %{meetings: meetings, scopes: scopes, farah: farah})
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

  defp check(c, scopes, who, expected) do
    for {key, cells} <- expected, {outcome, actions} <- cells, action <- actions do
      subject = {:meeting, Meetings.subject(Map.fetch!(c.meetings, key))}
      got = Access.why_not(Map.fetch!(scopes, who), action, subject)

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

  test "the words, and the same answers through Core.Meetings", c do
    put_level(c, :view)
    muaz = scope_for(c.muaz)
    m1 = c.meetings.m1
    now = ~U[2026-11-11 09:00:00.000000Z]

    assert Meetings.cancel(muaz, m1.id, %{}, now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert Meetings.cancel(c.scopes.tanweer, m1.id, %{}, now) ==
             {:error, {:forbidden, "That is for the team serving you to do."}}

    assert {:ok, %{id: _, can: %{cancel: false}}} = Meetings.get(muaz, m1.id)
    put_level(c, :hidden)
    assert Meetings.get(scope_for(c.muaz), m1.id) == {:error, :not_found}
    assert Meetings.get(c.scopes.naveed, m1.id) == {:error, :not_found}
    assert Meetings.get(scope_for(c.hira), c.meetings.m4.id) == {:error, :not_found}
    assert {:ok, _} = Meetings.get(c.scopes.tanweer, m1.id)
  end
end
