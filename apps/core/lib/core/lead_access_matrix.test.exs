defmodule Core.LeadAccessMatrixTest do
  @moduledoc """
  AQ-04A §4.3, cell by cell: every chair of the cast × four leads × every
  action of §4.2 (`Core.Access.Leads.actions/0`), **three times**, with both
  teams' `peer_leads` at `hidden`, `view` and `edit`.

  The leads: L1 Fiza's for Tanweer in Backend squad (To do); L2 Qasim's for
  Tanweer in Backend squad (applied by him, In progress); L3 Hira's for
  Imran in Frontend squad; L4 a lead in another organisation. The chairs:
  Dawud (the system admin), Hira (lead of both), Bilal (lead of Backend),
  Fiza (member of both), Qasim and Muaz (members of Backend), Farah (a
  member of Frontend only), the portal scopes of Tanweer and Naveed, and a
  signed-in stranger. Then the same answers through the contexts, and the
  lead not made yet (the team serves the customer, or words). AQ-04B adds
  the note, follow-up, label and task rows (`:note`, `:follow_up`, `:label`,
  `:add_task`: whoever may change the lead; a note's own words at `view`)
  and the Tracker by `peer_leads`; the labels and saved-views matrix is
  `Core.Leads.LabelsTest` and `Core.SavedViewsTest`.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Leads, as: LeadAccess
  alias Core.Leads
  alias Core.Leads.Portal
  alias Core.Leads.Tracker

  @now ~U[2026-11-11 09:00:00.000000Z]
  @actions LeadAccess.actions()
  @change LeadAccess.change_actions()
  @keep [:archive, :unarchive, :pin, :unpin]
  @never [:create, :applied]

  # A team lead, the system admin, the owner: everything a staff chair can.
  @full %{ok: @actions -- @never, not_found: @never}
  # A member at `edit`: the moves, not the hand-on, the archive or the pin.
  @editor %{ok: [:read, :share, :note | @change], forbidden: [:assign | @keep], not_found: @never}
  # A member at `view`: reads and shares, every change refused in words.
  @viewer %{
    ok: [:read, :share],
    forbidden: @change ++ [:note, :assign | @keep],
    not_found: @never
  }
  @hidden %{not_found: @actions}

  @fixed [
    {:dawud, %{l1: @full, l2: @full, l3: @full, l4: @hidden}},
    {:hira, %{l1: @full, l2: @full, l3: @full, l4: @hidden}},
    {:bilal, %{l1: @full, l2: @full, l3: @hidden, l4: @hidden}},
    {:tanweer,
     %{
       l1: %{ok: [:read, :applied], forbidden: @actions -- [:read, :applied]},
       l2: %{ok: [:read], forbidden: @actions -- [:read]},
       l3: @hidden,
       l4: @hidden
     }},
    {:naveed, %{l1: @hidden, l2: @hidden, l3: @hidden, l4: @hidden}},
    {:stranger, %{l1: @hidden, l2: @hidden, l3: @hidden, l4: @hidden}}
  ]

  @levels [
    hidden: [
      {:fiza, %{l1: @full, l2: @hidden, l3: @hidden, l4: @hidden}},
      {:qasim, %{l1: @hidden, l2: @full, l3: @hidden, l4: @hidden}},
      {:muaz, %{l1: @hidden, l2: @hidden, l3: @hidden, l4: @hidden}},
      {:farah, %{l1: @hidden, l2: @hidden, l3: @hidden, l4: @hidden}}
    ],
    view: [
      {:fiza, %{l1: @full, l2: @viewer, l3: @viewer, l4: @hidden}},
      {:qasim, %{l1: @viewer, l2: @full, l3: @hidden, l4: @hidden}},
      {:muaz, %{l1: @viewer, l2: @viewer, l3: @hidden, l4: @hidden}},
      {:farah, %{l1: @hidden, l2: @hidden, l3: @viewer, l4: @hidden}}
    ],
    edit: [
      {:fiza, %{l1: @full, l2: @editor, l3: @editor, l4: @hidden}},
      {:qasim, %{l1: @editor, l2: @full, l3: @hidden, l4: @hidden}},
      {:muaz, %{l1: @editor, l2: @editor, l3: @hidden, l4: @hidden}},
      {:farah, %{l1: @hidden, l2: @hidden, l3: @editor, l4: @hidden}}
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

    leads =
      for {key, lead} <- [l1: l1, l2: l2, l3: l3, l4: l4],
          into: %{},
          do: {key, Data.Leads.reload(lead)}

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

    Map.merge(c, %{leads: leads, scopes: scopes, farah: farah, imran_profile: imran_profile})
  end

  defp put_level(c, level) do
    for team <- [c.backend, c.frontend],
        do: {:ok, _} = Data.Teams.put_settings(team.id, %{peer_leads: level})
  end

  # The scopes read the team settings when they are built, so rebuild them.
  defp rescope(c) do
    Map.new(c.scopes, fn
      {who, %{roles: %{customer_id: id}} = scope} when is_binary(id) -> {who, scope}
      {who, scope} -> {who, scope_for(scope.user)}
    end)
  end

  defp check(scopes, leads, who, expected) do
    for {key, cells} <- expected, {outcome, actions} <- cells, action <- actions do
      got =
        Access.why_not(
          Map.fetch!(scopes, who),
          action,
          {:lead, Leads.subject(Map.fetch!(leads, key))}
        )

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
        check(rescope(c), c.leads, unquote(who), unquote(Macro.escape(expected)))
      end
    end
  end

  for {level, rows} <- @levels, {who, expected} <- rows do
    test "#{who}, peer_leads #{level}", c do
      put_level(c, unquote(level))
      check(rescope(c), c.leads, unquote(who), unquote(Macro.escape(expected)))
    end
  end

  test "the words: at view the view-only words; the hand-on and the keep words", c do
    put_level(c, :view)
    muaz = scope_for(c.muaz)
    subject = {:lead, Leads.subject(c.leads.l1)}

    assert Access.why_not(muaz, :move, subject) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

    assert Access.why_not(muaz, :assign, subject) ==
             {:error, {:forbidden, "Only the owner or a team lead can hand this lead on."}}

    assert Access.why_not(muaz, :archive, subject) ==
             {:error,
              {:forbidden, "Only the lead's owner, or a team lead, can archive or pin it."}}
  end

  test "a lead not made yet: a member of the job's team, for a customer the team serves", c do
    serves = %{team_id: c.backend.id, team_name: "Backend squad", customer: c.tanweer}
    imran = %{team_id: c.backend.id, team_name: "Backend squad", customer: c.imran}

    assert Access.can?(c.scopes.muaz, :create, {:lead, serves})
    assert Access.can?(c.scopes.dawud, :create, {:lead, serves})

    assert Access.why_not(c.scopes.muaz, :create, {:lead, imran}) ==
             {:error, {:forbidden, "Backend squad doesn't serve Imran."}}

    assert Access.why_not(c.scopes.farah, :create, {:lead, serves}) == {:error, :not_found}
    assert Access.why_not(c.scopes.tanweer, :create, {:lead, serves}) == {:error, :not_found}
  end

  test "through the contexts: the sheet, the board and the portal follow the same rows", c do
    put_level(c, :hidden)
    assert Leads.get(scope_for(c.muaz), c.leads.l1.id, @now) == {:error, :not_found}
    put_level(c, :view)

    assert {:ok, %{can: %{move: false, share: true}}} =
             Leads.get(scope_for(c.muaz), c.leads.l1.id, @now)

    put_level(c, :edit)

    assert {:ok, %{can: %{move: true, archive: false}}} =
             Leads.get(scope_for(c.muaz), c.leads.l1.id, @now)

    assert Leads.get(scope_for(c.farah), c.leads.l1.id, @now) == {:error, :not_found}
    assert Leads.get(scope_for(c.hira), c.leads.l4.id, @now) == {:error, :not_found}
  end

  test "the Tracker follows peer_leads; another team finds nothing (AQ-04B §4)", c do
    tracker = fn who ->
      case Tracker.page(scope_for(who), %{"team_id" => c.backend.id}, @now) do
        {:ok, page} -> page.items |> Enum.map(& &1.id) |> Enum.sort()
        error -> error
      end
    end

    both = Enum.sort([c.leads.l1.id, c.leads.l2.id])

    put_level(c, :hidden)
    assert tracker.(c.muaz) == []
    assert tracker.(c.fiza) == [c.leads.l1.id]
    assert tracker.(c.bilal) == both
    assert tracker.(c.dawud) == both

    put_level(c, :view)
    assert tracker.(c.muaz) == both
    assert tracker.(c.farah) == {:error, :not_found}

    assert Tracker.page(c.scopes.tanweer, %{"team_id" => c.backend.id}, @now) ==
             {:error, :not_found}
  end

  test "Tanweer finds none of Naveed's leads; Naveed's own list holds only his", c do
    naveed_profile = profile_fixture(c.naveed, title: "Golang")
    naveeds = lead_fixture(scope_for(c.fiza), team: c.backend, profile: naveed_profile)

    assert Leads.get(c.scopes.tanweer, naveeds.id, @now) == {:error, :not_found}
    {:ok, tanweer_list} = Portal.list(c.scopes.tanweer, @now)

    ids =
      Enum.flat_map(
        [:todo, :in_progress, :on_hold, :done],
        &Enum.map(tanweer_list[&1], fn r -> r.id end)
      )

    assert Enum.sort(ids) == Enum.sort([c.leads.l1.id, c.leads.l2.id])

    {:ok, naveed_list} = Portal.list(c.scopes.naveed, @now)
    assert Enum.map(naveed_list.todo, & &1.id) == [naveeds.id]
  end
end
