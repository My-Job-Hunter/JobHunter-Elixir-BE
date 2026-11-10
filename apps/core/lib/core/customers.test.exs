defmodule Core.CustomersTest do
  @moduledoc """
  The customer's life from the staff side (JH-01 §6.2) and the portal
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
    manager = member_fixture(frontend, :manager)

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: scope_for(admin),
      lead: scope_for(lead),
      manager: scope_for(manager)
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

  test "list: a manager sees their teams' and the unassigned; filters by team, status, q and mine",
       %{
         manager: manager,
         admin: admin,
         lead: lead,
         backend: backend,
         frontend: frontend,
         org: org
       } do
    tanweer = customer_fixture(org, [backend], display_name: "Tanweer")
    imran = customer_fixture(org, [frontend], display_name: "Imran")
    lone = customer_fixture(org, [], display_name: "Lone")
    profile_fixture(imran, owners: [manager.user])

    names = fn {:ok, list} -> list |> Enum.map(& &1.display_name) |> Enum.sort() end

    assert names.(Customers.list(manager)) == ["Imran", "Lone"]
    assert names.(Customers.list(manager, %{"team_id" => frontend.id})) == ["Imran"]
    assert names.(Customers.list(manager, %{"team_id" => backend.id})) == []
    assert names.(Customers.list(manager, %{"mine" => "true"})) == ["Imran"]
    assert names.(Customers.list(admin)) == ["Imran", "Lone", "Tanweer"]
    assert names.(Customers.list(admin, %{"q" => "tan"})) == ["Tanweer"]
    assert names.(Customers.list(lead)) == ["Tanweer"]
    assert Customers.list(lead, %{"status" => "nope"}) == {:error, {:missing, :status}}
    assert Customers.get(lead, lone.id) == {:error, :not_found}
    assert {:ok, _lone} = Customers.get(manager, lone.id)
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

  test "the portal's update touches contact details only; remove_team; a customer with no team stays listed for a manager",
       %{
         lead: lead,
         manager: manager,
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
    assert {:ok, _seen} = Customers.get(manager, customer.id)
    assert Customers.remove_team(lead, customer.id, backend.id, @now) == {:error, :not_found}
  end
end
