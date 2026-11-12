defmodule Core.CustomersTest do
  @moduledoc """
  The customer's life from the staff side (AQ-01 §6.2) and the portal
  invitation end to end: issued by a lead, accepted by the person, the
  login attached and the status active, in one transaction with its audit
  rows. The matrix (`Core.AccessMatrixTest`) covers who may; this covers
  what happens.
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Customers
  alias Core.Organisation.Invitations
  alias Data.Audit

  @now ~U[2026-11-09 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)
    front_lead = member_fixture(frontend, :lead)
    member = member_fixture(backend, :member)

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: scope_for(admin),
      lead: scope_for(lead),
      front_lead: scope_for(front_lead),
      member: scope_for(member)
    }
  end

  test "create puts the customer in the named teams, takes the organisation's zone, audits", %{
    lead: lead,
    backend: backend,
    frontend: frontend,
    org: org
  } do
    assert {:ok, customer} =
             Customers.create(
               lead,
               %{
                 "display_name" => "Tanweer",
                 "email" => "T@Example.com",
                 "team_ids" => [backend.id]
               },
               @now
             )

    assert customer.email == "t@example.com"
    assert customer.timezone == org.timezone
    assert customer.status == :invited
    assert customer.team_ids == [backend.id]

    assert Enum.map(Audit.list_for_subject(org.id, "customers", customer.id), & &1.action) ==
             ["team_assigned", "created"]
             |> Enum.sort()
             |> then(fn _ ->
               Audit.list_for_subject(org.id, "customers", customer.id) |> Enum.map(& &1.action)
             end)

    # A team the lead is not in is not found, and nothing is written.
    assert Customers.create(
             lead,
             %{"display_name" => "X", "email" => "x@example.com", "team_ids" => [frontend.id]},
             @now
           ) ==
             {:error, :not_found}

    assert {:ok, listed} = Customers.list(lead)
    assert Enum.map(listed, & &1.display_name) == ["Tanweer"]
  end

  test "create needs team_ids, each a team the caller leads (§8.5)", %{
    member: member,
    lead: lead,
    admin: admin,
    backend: backend,
    frontend: frontend
  } do
    body = %{"display_name" => "X", "email" => "x@example.com"}

    assert Customers.create(lead, body, @now) ==
             {:error, {:invalid, %{"team_ids" => ["is required"]}}}

    assert Customers.create(member, Map.put(body, "team_ids", [backend.id]), @now) ==
             {:error, {:forbidden, "Only a lead of that team can add a customer to it."}}

    assert {:ok, made} = Customers.create(admin, Map.put(body, "team_ids", [frontend.id]), @now)
    assert made.team_ids == [frontend.id]
  end

  test "another team for a customer the caller reaches: a lead of that team, or the system admin",
       %{
         org: org,
         lead: lead,
         backend: backend,
         frontend: frontend
       } do
    customer = customer_fixture(org, [backend])

    # Hira-like: a lead of both teams adds the customer to the other one.
    member_fixture(frontend, :lead, lead.user)
    both = scope_for(lead.user)
    assert {:ok, %{team_ids: ids}} = Customers.assign_team(both, customer.id, frontend.id, @now)
    assert Enum.sort(ids) == Enum.sort([backend.id, frontend.id])

    # Staff of a serving team who leads another team adds the customer there;
    # a team they only work in is refused with words, one they are not in is not found.
    other = team_fixture(org)
    worker = member_fixture(backend, :member)
    member_fixture(other, :lead, worker)

    assert {:ok, %{team_ids: ids}} =
             Customers.assign_team(scope_for(worker), customer.id, other.id, @now)

    assert other.id in ids

    plain = member_fixture(backend, :member)

    assert Customers.assign_team(scope_for(plain), customer.id, other.id, @now) ==
             {:error, {:forbidden, "Only a team lead can do that for a customer."}}

    assert Customers.assign_team(scope_for(worker), customer.id, frontend.id, @now) ==
             {:error, :not_found}
  end

  test "list: a lead sees their teams' (never the unassigned); filters by team, status, q and mine",
       %{
         front_lead: front_lead,
         admin: admin,
         lead: lead,
         backend: backend,
         frontend: frontend,
         org: org
       } do
    tanweer = customer_fixture(org, [backend], display_name: "Tanweer")
    imran = customer_fixture(org, [frontend], display_name: "Imran")
    lone = customer_fixture(org, [], display_name: "Lone")
    profile_fixture(imran, owners: [front_lead.user])

    names = fn {:ok, list} -> list |> Enum.map(& &1.display_name) |> Enum.sort() end

    assert names.(Customers.list(front_lead)) == ["Imran"]
    assert names.(Customers.list(front_lead, %{"team_id" => frontend.id})) == ["Imran"]
    assert names.(Customers.list(front_lead, %{"team_id" => backend.id})) == []
    assert names.(Customers.list(front_lead, %{"mine" => "true"})) == ["Imran"]
    assert names.(Customers.list(admin)) == ["Imran", "Lone", "Tanweer"]
    assert names.(Customers.list(admin, %{"q" => "tan"})) == ["Tanweer"]
    assert names.(Customers.list(lead)) == ["Tanweer"]
    assert Customers.list(lead, %{"status" => "nope"}) == {:error, {:missing, :status}}
    assert Customers.get(lead, lone.id) == {:error, :not_found}
    assert Customers.get(front_lead, lone.id) == {:error, :not_found}
    assert {:ok, _lone} = Customers.get(admin, lone.id)
    assert {:ok, _tanweer} = Customers.get(lead, tanweer.id)
  end

  test "change_status is audited with before and after; the dates follow", %{
    lead: lead,
    backend: backend,
    org: org
  } do
    customer = customer_fixture(org, [backend])

    assert {:ok, active} = Customers.change_status(lead, customer.id, "active", @now)
    assert active.status == :active and active.started_on == ~D[2026-11-09]
    assert {:ok, ended} = Customers.change_status(lead, customer.id, :ended, @now)
    assert ended.ended_on == ~D[2026-11-09]

    [event | _rest] =
      org.id
      |> Audit.list_for_subject("customers", customer.id)
      |> Enum.filter(&(&1.action == "status_changed"))

    assert event.before["status"] == "invited" and event.after["status"] == "active"
    assert event.actor_user_id == lead.user.id
  end

  test "invite issues a customer invitation; accepting attaches the login and makes them active; the portal is the landing",
       %{lead: lead, backend: backend, org: org} do
    customer =
      customer_fixture(org, [backend], display_name: "Tanweer", email: "tanweer@example.com")

    assert {:ok, invitation, :issued} = Customers.invite(lead, customer.id, @now)
    assert invitation.kind == :customer and invitation.email == "tanweer@example.com"
    assert invitation.customer_id == customer.id
    assert Invitations.accept_url(invitation) =~ "localhost:5801/invite/"
    assert_enqueued(worker: Notifire.Workers.InvitationWorker)

    # Again: the open one, not a second.
    assert {:ok, %{id: same}, :open} = Customers.invite(lead, customer.id, @now)
    assert same == invitation.id

    assert {:ok, %{user: user, landing: "/profiles", how: :created}} =
             Invitations.accept(
               invitation.code,
               %{"name" => "Tanweer A", "password" => "a fine long password"},
               now: @now
             )

    assert user.email == "tanweer@example.com"
    joined = Data.Customers.get(org.id, customer.id)
    assert joined.user_id == user.id and joined.status == :active

    scope = customer_scope_for(joined)
    assert Data.Scope.customer_id(scope) == customer.id
    assert {:ok, %{id: id}} = Customers.get(scope, customer.id)
    assert id == customer.id

    # A customer with a login cannot be invited again.
    assert Customers.invite(lead, customer.id, @now) == {:error, :conflict}

    actions = org.id |> Audit.list_for_subject("customers", customer.id) |> Enum.map(& &1.action)
    assert "joined" in actions
  end

  test "the portal's update touches contact details only; remove_team; a customer with no team stays seen by the system admin",
       %{
         lead: lead,
         admin: admin,
         backend: backend,
         org: org
       } do
    customer = customer_fixture(org, [backend], login: true, display_name: "Tanweer")
    scope = customer_scope_for(customer)

    assert {:ok, updated} =
             Customers.update(scope, customer.id, %{
               "phone_e164" => "+923001234567",
               "display_name" => "Other",
               "email" => "o@o.co"
             })

    assert updated.phone_e164 == "+923001234567" and updated.display_name == "Tanweer"

    assert {:ok, bare} = Customers.remove_team(lead, customer.id, backend.id, @now)
    assert bare.team_ids == []
    assert Customers.get(lead, customer.id) == {:error, :not_found}
    assert {:ok, _seen} = Customers.get(admin, customer.id)
    assert Customers.remove_team(lead, customer.id, backend.id, @now) == {:error, :not_found}
  end
end
