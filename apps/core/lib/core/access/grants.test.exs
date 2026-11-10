defmodule Core.Access.GrantsTest do
  use Core.CoreCase, async: true

  alias Core.Access.Grants
  alias Data.Scope

  test "an admin's scope says so, with their organisation" do
    org = organisation_fixture()
    admin = admin_fixture(org)

    scope = Grants.scope_for(admin, request_id: "r1")

    assert scope.organisation.id == org.id
    assert scope.roles == %{admin?: true, teams: %{}, customer_id: nil, team_settings: %{}}
    assert scope.via == :web
    assert scope.request_id == "r1"
  end

  test "team roles are read from the open memberships only" do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    user = member_fixture(backend, :lead)
    member_fixture(frontend, :member, user)

    {:ok, _left} =
      Data.Teams.leave(Data.Teams.get_open_member(frontend.id, user.id), DateTime.utc_now())

    scope = Grants.scope_for(user)

    assert scope.roles.teams == %{backend.id => :lead}
    refute Scope.admin?(scope)
    assert scope.organisation.id == org.id
  end

  test "an account with no role falls back to the one organisation" do
    org = organisation_fixture()
    user = user_fixture()

    scope = Grants.scope_for(user)

    assert scope.organisation.id == org.id
    assert scope.roles == Scope.no_roles()
  end

  test "a membership in an archived team is not a role" do
    org = organisation_fixture()
    team = team_fixture(org)
    user = member_fixture(team, :manager)
    {:ok, _archived} = Data.Teams.archive(team, DateTime.utc_now())

    assert Grants.scope_for(user).roles.teams == %{}
  end
end

defmodule Core.Access.GrantsCustomerTest do
  use Core.CoreCase, async: true

  alias Core.Access.Grants
  alias Data.Scope

  test "a customer's login resolves to roles.customer_id, with the organisation" do
    org = organisation_fixture()
    team = team_fixture(org)
    customer = customer_fixture(org, [team], login: true)

    scope = Grants.scope_for(Data.Accounts.get_user(customer.user_id))
    assert scope.organisation.id == org.id

    assert scope.roles == %{
             admin?: false,
             teams: %{},
             customer_id: customer.id,
             team_settings: %{}
           }

    assert Scope.customer?(scope)
    assert %Scope{roles: %{customer_id: id}} = Scope.pin_to_customer(scope)
    assert id == customer.id
  end

  test "team_settings carries each of the caller's teams' toggles, code defaults when unwritten" do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    user = member_fixture(backend, :lead)
    member_fixture(frontend, :member, user)
    {:ok, _settings} = Data.Teams.put_settings(backend.id, %{customer_sees_staff_names: false})

    scope = Grants.scope_for(user)
    assert Scope.team_settings(scope, backend.id).customer_sees_staff_names == false
    assert Scope.team_settings(scope, frontend.id).customer_sees_staff_names == true
    assert Scope.team_settings(scope, Ecto.UUID.generate()) == nil
    refute Scope.customer?(scope)
    assert Scope.pin_to_customer(scope) == nil
  end
end
