defmodule Data.ScopeTest do
  use ExUnit.Case, async: true

  alias Data.Scope

  test "for_user carries the user and no roles yet" do
    scope = Scope.for_user(%{id: "u1"})
    assert Scope.user_id(scope) == "u1"
    assert scope.roles == %{admin?: false, teams: %{}, customer_id: nil, team_settings: %{}}
    assert scope.via == :web
    refute Scope.admin?(scope)
  end

  test "system acts for an organisation with nobody as the actor" do
    scope = Scope.system(%{id: "o1"})
    assert Scope.user_id(scope) == nil
    assert Scope.organisation_id(scope) == "o1"
    assert scope.via == :system
  end

  test "the role helpers read the resolved roles" do
    scope = %Scope{
      roles: %{
        admin?: true,
        teams: %{"t1" => :lead, "t2" => :member},
        customer_id: nil,
        team_settings: %{}
      }
    }

    assert Scope.admin?(scope)
    assert Scope.team_role(scope, "t1") == :lead
    assert Scope.team_role(scope, "t9") == nil
    assert Enum.sort(Scope.team_ids(scope)) == ["t1", "t2"]
    assert Scope.any_team?(scope, :lead)
    refute Scope.any_team?(scope, :manager)
    assert Scope.team_ids(%Scope{}) == []
  end
end
