defmodule Core.ApprovalAccessMatrixTest do
  @moduledoc """
  AQ-07 §4, cell by cell: every chair × six approvals × every action
  (`Core.Access.Approvals.actions/0`), **three times**, with the teams'
  `peer_leads` at `hidden`, `view` and `edit` — an approval on a lead is
  read by whoever reads the lead; the requester, a named person, the
  team's leads and the system admin whatever the level; a draft the
  requester's, the leads' and the admin's alone; the customer only with a
  slot. Deciding is a reviewer's (`not_reviewer` for anyone else who sees
  it, the requester too); changing is the requester's, a team lead's or
  the admin's. Then the same answers through the contexts, and asking.

  The approvals: A1 on L1 (Fiza's, Backend, Tanweer) with a customer slot;
  A2 on L1 with a team-lead slot alone; A3 on L2 (Qasim's) naming Muaz; A4
  a draft on L1; A5 Muaz's profile change on *Golang backend*; A6 another
  organisation's.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Approvals, as: ApprovalAccess
  alias Core.Approvals
  alias Core.Approvals.{Act, Sheet}

  @now ~U[2026-11-12 09:00:00.000000Z]
  @actions ApprovalAccess.actions()
  @change ApprovalAccess.change_actions()

  @lead %{ok: [:read, :comment | @change], not_reviewer: [:decide]}
  @lead_reviewer %{ok: @actions}
  @asker %{ok: [:read, :comment | @change], not_reviewer: [:decide]}
  @viewer %{ok: [:read, :comment], not_reviewer: [:decide], forbidden: @change}
  @named %{ok: [:read, :comment, :decide], forbidden: @change}
  @customer %{ok: [:read, :comment, :decide], forbidden: @change}
  @hidden %{not_found: @actions}

  @all_hidden %{a1: @hidden, a2: @hidden, a3: @hidden, a4: @hidden, a5: @hidden, a6: @hidden}

  @fixed [
    {:dawud, %{a1: @lead, a2: @lead, a3: @lead, a4: @lead, a5: @lead, a6: @hidden}},
    {:hira, %{a1: @lead, a2: @lead_reviewer, a3: @lead, a4: @lead, a5: @lead, a6: @hidden}},
    {:bilal, %{a1: @lead, a2: @lead_reviewer, a3: @lead, a4: @lead, a5: @lead, a6: @hidden}},
    {:tanweer, %{@all_hidden | a1: @customer, a5: @customer}},
    {:naveed, @all_hidden},
    {:farah, @all_hidden},
    {:stranger, @all_hidden}
  ]

  @levels [
    hidden: [
      {:fiza, %{@all_hidden | a1: @asker, a2: @asker, a4: @asker}},
      {:qasim, %{@all_hidden | a3: @asker}},
      {:muaz, %{@all_hidden | a3: @named, a5: @asker}}
    ],
    view: [
      {:fiza, %{@all_hidden | a1: @asker, a2: @asker, a3: @viewer, a4: @asker}},
      {:qasim, %{@all_hidden | a1: @viewer, a2: @viewer, a3: @asker}},
      {:muaz, %{@all_hidden | a1: @viewer, a2: @viewer, a3: @named, a5: @asker}}
    ],
    edit: [
      {:fiza, %{@all_hidden | a1: @asker, a2: @asker, a3: @viewer, a4: @asker}},
      {:qasim, %{@all_hidden | a1: @viewer, a2: @viewer, a3: @asker}},
      {:muaz, %{@all_hidden | a1: @viewer, a2: @viewer, a3: @named, a5: @asker}}
    ]
  ]

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    fiza = scope_for(c.fiza)
    qasim = scope_for(c.qasim)
    l1 = lead_fixture(fiza, team: c.backend, profile: c.golang)
    l2 = lead_fixture(qasim, team: c.backend, profile: c.golang, state: :in_progress)

    other = organisation_fixture()
    other_team = team_fixture(other)
    outsider = member_fixture(other_team, :lead)
    l6 = lead_fixture(scope_for(outsider), team: other_team)

    approvals = %{
      a1: approval_fixture(fiza, lead: l1, state: :pending, slots: [:customer]),
      a2: approval_fixture(fiza, lead: l1, state: :pending, slots: [:team_lead]),
      a3: approval_fixture(qasim, lead: l2, state: :pending, slots: [{:user, c.muaz}]),
      a4: approval_fixture(fiza, lead: l1, state: :draft, slots: [:customer]),
      a5:
        approval_fixture(scope_for(c.muaz), profile: c.golang, team: c.backend, state: :pending),
      a6: approval_fixture(scope_for(outsider), lead: l6, state: :pending)
    }

    scopes = %{
      dawud: scope_for(c.dawud),
      hira: scope_for(c.hira),
      bilal: scope_for(c.bilal),
      fiza: fiza,
      qasim: qasim,
      muaz: scope_for(c.muaz),
      farah: scope_for(farah),
      tanweer: customer_scope_for(c.tanweer),
      naveed: customer_scope_for(c.naveed),
      stranger: scope_for(user_fixture())
    }

    Map.merge(c, %{approvals: approvals, scopes: scopes})
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
      subject = {:approval, Sheet.subject(Map.fetch!(c.approvals, key))}
      got = Access.why_not(Map.fetch!(scopes, who), action, subject)

      assert classify(got) == outcome,
             "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"
    end

    for {_key, cells} <- expected,
        do: assert(Enum.sort(Enum.flat_map(cells, &elem(&1, 1))) == Enum.sort(@actions))
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, :not_reviewer}), do: :not_reviewer
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

  test "the words, and the same answers through the contexts", c do
    put_level(c, :view)
    a1 = c.approvals.a1

    assert Act.decide(
             scope_for(c.qasim),
             a1.id,
             %{decision: "approved", version: 1},
             @now
           ) ==
             {:error, :not_reviewer}

    assert Act.withdraw(scope_for(c.qasim), a1.id, @now) ==
             {:error, {:forbidden, "Only whoever asked, or a team lead, can change this."}}

    assert Act.withdraw(c.scopes.tanweer, a1.id, @now) ==
             {:error, {:forbidden, "That is for the team serving you to do."}}

    assert {:ok, %{team: nil, can: can}} = Approvals.get(c.scopes.tanweer, a1.id, @now)

    assert can == %{
             edit: false,
             submit: false,
             decide: true,
             revise: false,
             withdraw: false,
             comment: true,
             sent: false
           }

    assert Approvals.get(c.scopes.naveed, a1.id, @now) == {:error, :not_found}
    assert Approvals.get(c.scopes.tanweer, c.approvals.a2.id, @now) == {:error, :not_found}
    assert Approvals.get(scope_for(c.hira), c.approvals.a6.id, @now) == {:error, :not_found}
    put_level(c, :hidden)
    assert Approvals.get(scope_for(c.qasim), a1.id, @now) == {:error, :not_found}
  end

  test "asking: whoever may change the lead (P4a's words at view); a profile change, staff serving the customer",
       c do
    put_level(c, :view)
    l1 = c.approvals.a1.lead

    body = %{
      team_id: c.backend.id,
      lead_id: l1.id,
      approval_kind: "asset",
      title: "x",
      slots: [%{slot: "team_lead"}]
    }

    assert Approvals.draft(scope_for(c.qasim), body, @now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert Approvals.draft(scope_for(c.fiza), body, @now) |> elem(0) == :ok
    assert Approvals.draft(c.scopes.tanweer, body, @now) == {:error, :not_found}
    assert Approvals.draft(c.scopes.stranger, body, @now) == {:error, :not_found}

    put_level(c, :edit)
    assert {:ok, %{state: :draft}} = Approvals.draft(scope_for(c.qasim), body, @now)

    profile = %{
      team_id: c.frontend.id,
      profile_id: c.golang.id,
      approval_kind: "profile_change",
      title: "x",
      proposed: %{headline: "y"}
    }

    assert {:error, {:invalid, %{"team_id" => _}}} =
             Approvals.draft(scope_for(c.hira), profile, @now)

    assert {:error, :not_found} =
             Approvals.draft(c.scopes.farah, %{profile | team_id: c.backend.id}, @now)
  end
end
