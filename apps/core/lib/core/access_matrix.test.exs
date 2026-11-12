defmodule Core.AccessMatrixTest do
  @moduledoc """
  AQ-01 §5.3 as AQ-04A §4.0 and §8.5 settle it (no manager chair; one system
  admin), cell by cell, over **one fixture organisation**: two teams
  (Backend, Frontend); Dawud the system admin, in no team; Hira lead of both;
  Bilal lead of Backend; Fiza member of both; Qasim and Muaz members of
  Backend; customers Tanweer and Naveed (Backend), Imran (Frontend), Sara
  (invited, no login), and Lone — a customer in no team (QP1-8).

  Table-driven: `@rows` is one row per (person, subject), naming for
  **every action of §5.2** on that subject kind whether it is `:ok`,
  `:forbidden` (words) or `:not_found`. The test fails if a row leaves an
  action out, so a new action is a new cell in every row, and a changed
  cell is a changed row.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Customers
  alias Core.Customers.Channels
  alias Core.Customers.Documents
  alias Core.Customers.Notes
  alias Core.Customers.Profiles
  alias Data.Scope

  @actions %{
    organisation: [:read_settings, :update_settings, :read_audit],
    team: [
      :read,
      :create,
      :update,
      :archive,
      :read_settings,
      :update_settings,
      :list_members,
      :invite_member,
      :change_role,
      :remove_member
    ],
    invitation: [:create, :revoke, :read],
    customer: [
      :list,
      :read,
      :create,
      :update,
      :change_status,
      :assign_team,
      :read_notes,
      :write_note,
      :invite
    ],
    profile: [:read, :create, :update_facts, :update_pitch, :archive, :set_owners],
    channel: [:read, :create, :update, :archive],
    document: [:read, :create, :update, :archive, :download],
    pipeline: [:read, :edit],
    people: [:read_people],
    self: [:read_self, :update_self]
  }

  # ── The cast ────────────────────────────────────────────────────────────────

  # Built per test: the sandbox gives each test its own transaction, so a
  # cast built once in `setup_all` would be invisible to them.
  setup do
    org = organisation_fixture(name: "Regbits BD")
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")

    dawud = admin_fixture(org, display_name: "Dawud Kalim")
    hira = member_fixture(backend, :lead, user_fixture(display_name: "Hira Khan"))
    member_fixture(frontend, :lead, hira)
    bilal = member_fixture(backend, :lead, user_fixture(display_name: "Bilal"))
    fiza = member_fixture(backend, :member, user_fixture(display_name: "Fiza"))
    member_fixture(frontend, :member, fiza)
    qasim = member_fixture(backend, :member, user_fixture(display_name: "Qasim"))
    muaz = member_fixture(backend, :member, user_fixture(display_name: "Muaz"))

    tanweer = customer_fixture(org, [backend], display_name: "Tanweer", login: true)
    naveed = customer_fixture(org, [backend], display_name: "Naveed", login: true)
    imran = customer_fixture(org, [frontend], display_name: "Imran", login: true)
    sara = customer_fixture(org, [backend], display_name: "Sara")
    lone = customer_fixture(org, [], display_name: "Lone")

    subjects = %{
      org: {:organisation, org},
      backend: {:team, backend},
      frontend: {:team, frontend},
      backend_invitation: {:invitation, %{kind: :team_member, team_id: backend.id}},
      tanweer: {:customer, tanweer},
      imran: {:customer, imran},
      naveed: {:customer, naveed},
      sara: {:customer, sara},
      lone: {:customer, lone},
      tanweer_profile:
        {:profile, profile_fixture(tanweer, title: "Golang backend", owners: [fiza, qasim])},
      imran_profile: {:profile, profile_fixture(imran, title: "AI/ML")},
      lone_profile: {:profile, profile_fixture(lone)},
      tanweer_channel: {:channel, channel_fixture(tanweer)},
      imran_channel: {:channel, channel_fixture(imran)},
      pipeline: {:pipeline, :employment},
      people: :people,
      self: :self
    }

    subjects =
      Map.merge(subjects, %{
        tanweer_document: {:document, document_fixture(elem(subjects.tanweer_profile, 1))},
        imran_document: {:document, document_fixture(elem(subjects.imran_profile, 1))}
      })

    scopes = %{
      dawud: scope_for(dawud),
      hira: scope_for(hira),
      bilal: scope_for(bilal),
      fiza: scope_for(fiza),
      qasim: scope_for(qasim),
      muaz: scope_for(muaz),
      tanweer: customer_scope_for(tanweer),
      imran: customer_scope_for(imran)
    }

    %{
      scopes: scopes,
      subjects: subjects,
      customers: %{tanweer: tanweer, naveed: naveed, imran: imran}
    }
  end

  # ── The matrix ──────────────────────────────────────────────────────────────

  # {who, subject, %{ok: [...], forbidden: [...], not_found: [...]}} — or a
  # single atom when every action answers the same.
  @lead_team_actions [
    :read,
    :list_members,
    :read_settings,
    :update_settings,
    :invite_member,
    :remove_member
  ]
  @admin_team_actions [:create, :update, :archive, :change_role]

  @rows [
    # Dawud: the system admin. Everything, in every team.
    {:dawud, :org, :ok},
    {:dawud, :backend, :ok},
    {:dawud, :frontend, :ok},
    {:dawud, :backend_invitation, :ok},
    {:dawud, :tanweer, :ok},
    {:dawud, :imran, :ok},
    {:dawud, :lone, :ok},
    {:dawud, :tanweer_profile, :ok},
    {:dawud, :lone_profile, :ok},
    {:dawud, :tanweer_channel, :ok},
    {:dawud, :tanweer_document, :ok},
    {:dawud, :pipeline, :ok},
    {:dawud, :people, :ok},
    {:dawud, :self, :ok},

    # Hira: lead of both teams.
    {:hira, :org, %{forbidden: @actions.organisation}},
    {:hira, :backend, %{ok: @lead_team_actions, forbidden: @admin_team_actions}},
    {:hira, :frontend, %{ok: @lead_team_actions, forbidden: @admin_team_actions}},
    {:hira, :backend_invitation, :ok},
    {:hira, :tanweer, :ok},
    {:hira, :imran, :ok},
    {:hira, :sara, :ok},
    # A customer in no team is the system admin's alone (QP4a-23): a lead does not see them.
    {:hira, :lone, %{ok: [:list, :create], not_found: @actions.customer -- [:list, :create]}},
    {:hira, :lone_profile, %{not_found: @actions.profile}},
    {:hira, :tanweer_profile, :ok},
    {:hira, :imran_profile, :ok},
    {:hira, :tanweer_channel, :ok},
    {:hira, :imran_document, :ok},
    {:hira, :pipeline, :ok},
    {:hira, :people, :ok},
    {:hira, :self, :ok},

    # Bilal: lead of Backend only. Frontend and its customers do not exist for him.
    {:bilal, :backend, %{ok: @lead_team_actions, forbidden: @admin_team_actions}},
    {:bilal, :frontend, %{not_found: @actions.team -- [:create], forbidden: [:create]}},
    {:bilal, :tanweer, :ok},
    {:bilal, :imran, %{ok: [:list, :create], not_found: @actions.customer -- [:list, :create]}},
    {:bilal, :imran_profile, %{not_found: @actions.profile}},
    {:bilal, :imran_channel, %{not_found: @actions.channel}},
    {:bilal, :imran_document, %{not_found: @actions.document}},
    {:bilal, :tanweer_profile, :ok},
    {:bilal, :tanweer_document, :ok},

    # Fiza: member of both. Reads; edits facts, not the pitch; full run of channels and documents.
    {:fiza, :org, %{forbidden: @actions.organisation}},
    {:fiza, :backend,
     %{ok: [:read, :list_members], forbidden: @actions.team -- [:read, :list_members]}},
    {:fiza, :backend_invitation, %{forbidden: [:create], not_found: [:read, :revoke]}},
    {:fiza, :tanweer,
     %{
       ok: [:list, :read, :read_notes],
       forbidden: [:create, :update, :change_status, :assign_team, :write_note, :invite]
     }},
    {:fiza, :imran,
     %{
       ok: [:list, :read, :read_notes],
       forbidden: @actions.customer -- [:list, :read, :read_notes]
     }},
    {:fiza, :lone,
     %{forbidden: [:create], not_found: @actions.customer -- [:list, :create], ok: [:list]}},
    {:fiza, :tanweer_profile,
     %{ok: [:read, :update_facts], forbidden: [:create, :update_pitch, :archive, :set_owners]}},
    {:fiza, :imran_profile,
     %{ok: [:read, :update_facts], forbidden: [:create, :update_pitch, :archive, :set_owners]}},
    {:fiza, :tanweer_channel, :ok},
    {:fiza, :imran_channel, :ok},
    {:fiza, :tanweer_document, :ok},
    {:fiza, :pipeline, %{ok: [:read], forbidden: [:edit]}},
    {:fiza, :people, :ok},
    {:fiza, :self, :ok},

    # Qasim and Muaz: members of Backend only.
    {:qasim, :tanweer,
     %{
       ok: [:list, :read, :read_notes],
       forbidden: @actions.customer -- [:list, :read, :read_notes]
     }},
    {:qasim, :tanweer_profile,
     %{ok: [:read, :update_facts], forbidden: [:create, :update_pitch, :archive, :set_owners]}},
    {:muaz, :imran,
     %{ok: [:list], forbidden: [:create], not_found: @actions.customer -- [:list, :create]}},
    {:muaz, :imran_profile, %{not_found: @actions.profile}},
    {:muaz, :imran_channel, %{not_found: @actions.channel}},
    {:muaz, :imran_document, %{not_found: @actions.document}},
    {:muaz, :frontend, %{not_found: @actions.team -- [:create], forbidden: [:create]}},
    {:muaz, :tanweer_channel, :ok},
    {:muaz, :pipeline, %{ok: [:read], forbidden: [:edit]}},
    {:bilal, :pipeline, :ok},

    # Tanweer: a customer, from the portal. Their own, and nothing else.
    {:tanweer, :org, %{forbidden: @actions.organisation}},
    {:tanweer, :backend, %{not_found: @actions.team -- [:create], forbidden: [:create]}},
    {:tanweer, :backend_invitation, %{not_found: @actions.invitation}},
    {:tanweer, :tanweer,
     %{
       ok: [:read, :update],
       forbidden: [:create, :change_status, :assign_team, :write_note, :invite],
       not_found: [:list, :read_notes]
     }},
    {:tanweer, :naveed, %{forbidden: [:create], not_found: @actions.customer -- [:create]}},
    {:tanweer, :tanweer_profile,
     %{ok: [:read, :update_facts, :update_pitch], forbidden: [:create, :archive, :set_owners]}},
    {:tanweer, :imran_profile, %{not_found: @actions.profile}},
    {:tanweer, :tanweer_channel, :ok},
    {:tanweer, :imran_channel, %{not_found: @actions.channel}},
    {:tanweer, :tanweer_document, :ok},
    {:tanweer, :imran_document, %{not_found: @actions.document}},
    {:tanweer, :pipeline, %{not_found: [:read, :edit]}},
    {:tanweer, :people, %{not_found: [:read_people]}},
    {:tanweer, :self, :ok}
  ]

  for {who, subject, expected} <- @rows do
    test "#{who} on #{subject}: #{inspect(expected)}", %{scopes: scopes, subjects: subjects} do
      who = unquote(who)
      key = unquote(subject)
      expected = unquote(Macro.escape(expected))
      subject = Map.fetch!(subjects, key)
      actions = Map.fetch!(@actions, kind_of(subject))
      table = expand(expected, actions)

      assert Enum.sort(Map.keys(table)) == Enum.sort(actions),
             "the row for #{who}/#{key} must name every action of §5.2"

      for {action, outcome} <- table do
        got = Access.why_not(Map.fetch!(scopes, who), action, subject)

        assert classify(got) == outcome,
               "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"
      end
    end
  end

  defp kind_of({kind, _subject}), do: kind
  defp kind_of(atom) when is_atom(atom), do: atom

  defp expand(:ok, actions), do: Map.new(actions, &{&1, :ok})

  defp expand(%{} = cells, _actions) do
    for {outcome, acts} <- cells, action <- acts, into: %{}, do: {action, outcome}
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, {:forbidden, words}}) when is_binary(words), do: :forbidden

  # ── Beyond the cells ────────────────────────────────────────────────────────

  test "Tanweer's portal scope reaches none of Naveed's rows", %{
    scopes: scopes,
    customers: customers
  } do
    naveed = customers.naveed
    profile = profile_fixture(naveed, title: "Elixir")
    channel = channel_fixture(naveed)
    document = document_fixture(profile)

    assert Customers.get(scopes.tanweer, naveed.id) == {:error, :not_found}
    assert Profiles.list(scopes.tanweer, naveed.id) == {:error, :not_found}
    assert Profiles.get(scopes.tanweer, profile.id) == {:error, :not_found}
    assert Channels.get(scopes.tanweer, channel.id) == {:error, :not_found}
    assert Documents.get(scopes.tanweer, document.id) == {:error, :not_found}
    assert Documents.list(scopes.tanweer, profile.id) == {:error, :not_found}
    assert Notes.list(scopes.tanweer, naveed.id) == {:error, :not_found}
    assert Notes.list(scopes.tanweer, customers.tanweer.id) == {:error, :not_found}
  end

  test "a staff account on the portal is pinned to nobody", %{scopes: scopes} do
    assert Scope.pin_to_customer(scopes.fiza) == nil
    assert Scope.pin_to_customer(scopes.dawud) == nil
    assert %Scope{roles: %{teams: %{}, admin?: false}} = Scope.pin_to_customer(scopes.tanweer)
  end

  test "a member's update_pitch is refused with the §7.2 words", %{
    scopes: scopes,
    subjects: subjects
  } do
    {:profile, profile} = subjects.tanweer_profile

    assert Access.why_not(scopes.fiza, :update_pitch, subjects.tanweer_profile) ==
             {:error, {:forbidden, "The pitch is the customer's or a lead's to change."}}

    assert {:error, {:forbidden, "The pitch is the customer's or a lead's to change."}} =
             Profiles.update_pitch(scopes.qasim, profile.id, %{"headline" => "x"})
  end

  test "a lead of several teams reaches every customer of each, but not a customer in no team", %{
    subjects: subjects
  } do
    {:customer, tanweer} = subjects.tanweer
    {:customer, imran} = subjects.imran
    {:customer, lone} = subjects.lone
    lead = user_fixture(display_name: "Lead of both")

    for team_id <- tanweer.team_ids ++ imran.team_ids,
        do: member_fixture(%{id: team_id}, :lead, lead)

    scope = scope_for(lead)

    for customer <- [tanweer, imran], action <- @actions.customer do
      assert Access.can?(scope, action, {:customer, customer}),
             "lead #{action} #{customer.display_name}"
    end

    assert Access.why_not(scope, :read, {:customer, lone}) == {:error, :not_found}
    assert {:ok, listed} = Customers.list(scope)

    assert Enum.sort(Enum.map(listed, & &1.display_name)) == [
             "Imran",
             "Naveed",
             "Sara",
             "Tanweer"
           ]
  end

  test "nobody grants the system admin: there is no admin action left on the organisation", %{
    scopes: scopes,
    subjects: subjects
  } do
    for action <- [:list_admins, :grant_admin, :revoke_admin] do
      assert Access.why_not(scopes.dawud, action, subjects.org) == {:error, :not_found}
    end
  end

  test "a customer in no team (QP4a-23) is visible to the system admin only", %{
    scopes: scopes,
    subjects: subjects
  } do
    {:customer, lone} = subjects.lone

    assert Access.can?(scopes.dawud, :read, {:customer, lone})

    for who <- [:hira, :bilal, :fiza, :qasim, :muaz, :tanweer] do
      assert Access.why_not(scopes[who], :read, {:customer, lone}) == {:error, :not_found},
             "#{who}"
    end

    assert {:ok, listed} = Customers.list(scopes.hira)
    refute Enum.any?(listed, &(&1.id == lone.id))
    assert {:ok, listed} = Customers.list(scopes.dawud)
    assert Enum.any?(listed, &(&1.id == lone.id))
  end
end
