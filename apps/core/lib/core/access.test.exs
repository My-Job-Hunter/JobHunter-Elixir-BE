defmodule Core.AccessTest do
  @moduledoc """
  The P1.0/P1.1 columns of JH-01 §5.3, cell by cell, from each role's scope.
  Pure: scopes are built by hand. The matrix test over the fixture
  organisation (P1.3) extends this to customers.
  """

  use ExUnit.Case, async: true

  alias Core.Access
  alias Data.Scope

  @org %{id: "org"}
  @backend %{id: "backend"}
  @frontend %{id: "frontend"}

  defp scope(roles), do: %Scope{user: %{id: "u"}, organisation: @org, roles: roles}

  defp admin, do: scope(%{admin?: true, teams: %{}, customer_id: nil, team_settings: %{}})

  defp manager,
    do:
      scope(%{
        admin?: false,
        teams: %{"backend" => :manager},
        customer_id: nil,
        team_settings: %{}
      })

  defp lead,
    do:
      scope(%{admin?: false, teams: %{"backend" => :lead}, customer_id: nil, team_settings: %{}})

  defp member,
    do:
      scope(%{
        admin?: false,
        teams: %{"backend" => :member},
        customer_id: nil,
        team_settings: %{}
      })

  defp nobody, do: scope(Scope.no_roles())

  describe "the organisation" do
    test "settings are read by a lead or above and written by an admin" do
      for s <- [admin(), manager(), lead()],
          do: assert(Access.can?(s, :read_settings, {:organisation, @org}))

      refute Access.can?(member(), :read_settings, {:organisation, @org})

      assert Access.can?(admin(), :update_settings, {:organisation, @org})

      for s <- [manager(), lead(), member()],
          do: refute(Access.can?(s, :update_settings, {:organisation, @org}))
    end

    test "admins are an admin's; the audit log a manager's or an admin's" do
      for action <- [:list_admins, :grant_admin, :revoke_admin] do
        assert Access.can?(admin(), action, {:organisation, @org})
        refute Access.can?(manager(), action, {:organisation, @org})
      end

      assert Access.can?(manager(), :read_audit, {:organisation, @org})
      refute Access.can?(lead(), :read_audit, {:organisation, @org})
    end

    test "a refusal on a known subject is words, not 404" do
      assert {:error, {:forbidden, words}} =
               Access.why_not(member(), :update_settings, {:organisation, @org})

      assert words =~ "admin"
    end

    test "the system scope answers to nobody" do
      assert Access.can?(Scope.system(@org), :grant_admin, {:organisation, @org})
    end
  end

  describe "teams" do
    test "a team the caller is not in does not exist" do
      for s <- [manager(), lead(), member(), nobody()] do
        assert Access.why_not(s, :read, {:team, @frontend}) == {:error, :not_found}
      end

      assert Access.can?(admin(), :read, {:team, @frontend})
    end

    test "everyone in the team reads it and its members" do
      for s <- [manager(), lead(), member()], action <- [:read, :list_members] do
        assert Access.can?(s, action, {:team, @backend})
      end
    end

    test "a manager does everything in their team; a lead everything but the team itself" do
      for action <- [
            :update,
            :archive,
            :read_settings,
            :update_settings,
            :invite_member,
            :change_role,
            :remove_member
          ] do
        assert Access.can?(manager(), action, {:team, @backend}), "manager #{action}"
      end

      for action <- [
            :read_settings,
            :update_settings,
            :invite_member,
            :change_role,
            :remove_member
          ] do
        assert Access.can?(lead(), action, {:team, @backend}), "lead #{action}"
      end

      for action <- [:update, :archive] do
        assert {:error, {:forbidden, _words}} = Access.why_not(lead(), action, {:team, @backend})
      end
    end

    test "a member only reads" do
      for action <- [
            :update,
            :archive,
            :read_settings,
            :update_settings,
            :invite_member,
            :change_role,
            :remove_member
          ] do
        assert {:error, {:forbidden, _words}} =
                 Access.why_not(member(), action, {:team, @backend})
      end
    end

    test "creating a team is a manager's or an admin's" do
      assert Access.can?(admin(), :create, {:team, %{}})
      assert Access.can?(manager(), :create, {:team, %{}})
      refute Access.can?(lead(), :create, {:team, %{}})
    end
  end

  describe "invitations" do
    test "an admin invitation is an admin's to make" do
      assert Access.can?(admin(), :create, {:invitation, %{kind: :admin}})
      refute Access.can?(manager(), :create, {:invitation, %{kind: :admin}})
    end

    test "a team invitation follows invite_member on the team" do
      inv = %{kind: :team_member, team_id: "backend"}

      for s <- [admin(), manager(), lead()],
          do: assert(Access.can?(s, :create, {:invitation, inv}))

      refute Access.can?(member(), :create, {:invitation, inv})

      assert Access.why_not(
               lead(),
               :create,
               {:invitation, %{kind: :team_member, team_id: "frontend"}}
             ) ==
               {:error, :not_found}
    end

    test "a customer invitation is the customer's :invite: a lead of a serving team, not a member" do
      customer = %{id: "c1", team_ids: ["backend"]}
      inv = %{kind: :customer, customer: customer}

      for s <- [admin(), manager(), lead()],
          do: assert(Access.can?(s, :create, {:invitation, inv}))

      assert {:error, {:forbidden, _words}} =
               Access.why_not(member(), :create, {:invitation, inv})

      assert Access.why_not(
               lead(),
               :create,
               {:invitation, %{kind: :customer, customer: %{id: "c2", team_ids: ["frontend"]}}}
             ) == {:error, :not_found}

      assert Access.why_not(admin(), :create, {:invitation, %{kind: :customer, customer: nil}}) ==
               {:error, :not_found}
    end

    test "reading and revoking: an admin all, a lead their team's, a member none" do
      mine = %{kind: :team_member, team_id: "backend"}
      theirs = %{kind: :team_member, team_id: "frontend"}
      admin_inv = %{kind: :admin, team_id: nil}

      assert Access.can?(admin(), :revoke, {:invitation, admin_inv})
      assert Access.can?(lead(), :revoke, {:invitation, mine})
      assert Access.why_not(lead(), :read, {:invitation, theirs}) == {:error, :not_found}
      assert Access.why_not(lead(), :read, {:invitation, admin_inv}) == {:error, :not_found}
      assert Access.why_not(member(), :read, {:invitation, mine}) == {:error, :not_found}
    end
  end

  describe "people and self" do
    test "every staff account reads the staff list; an account with no role does not" do
      for s <- [admin(), manager(), lead(), member()],
          do: assert(Access.can?(s, :read_people, :people))

      assert Access.why_not(nobody(), :read_people, :people) == {:error, :not_found}
    end

    test "everyone reads and updates themselves" do
      for s <- [admin(), member(), nobody()], action <- [:read_self, :update_self] do
        assert Access.can?(s, action, :self)
      end
    end

    test "an unknown action is not found" do
      assert Access.why_not(admin(), :fly, {:team, @backend}) == :ok or
               Access.why_not(member(), :fly, :moon) == {:error, :not_found}
    end
  end
end
