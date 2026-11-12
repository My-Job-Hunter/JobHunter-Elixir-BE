defmodule Core.AccessTest do
  @moduledoc """
  The organisation, team and invitation columns of AQ-01 §5.3 as AQ-04A §8.5
  settles them (no manager; one system admin), cell by cell, from each
  role's scope. Pure: scopes are built by hand. The matrix test over the
  fixture organisation extends this to customers.
  """

  use ExUnit.Case, async: true

  alias Core.Access
  alias Data.Scope

  @org %{id: "org"}
  @backend %{id: "backend"}
  @frontend %{id: "frontend"}
  @admin_words "Only the system admin can do that."

  defp scope(roles), do: %Scope{user: %{id: "u"}, organisation: @org, roles: roles}

  defp admin, do: scope(%{admin?: true, teams: %{}, customer_id: nil, team_settings: %{}})

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

  describe "the organisation: Settings › System, the system admin's alone" do
    test "settings, the audit log and suspending are the system admin's, refused with §8.5's words" do
      for action <- [:read_settings, :update_settings, :read_audit, :suspend_user] do
        assert Access.can?(admin(), action, {:organisation, @org})

        for s <- [lead(), member()] do
          assert Access.why_not(s, action, {:organisation, @org}) ==
                   {:error, {:forbidden, @admin_words}}
        end
      end
    end

    test "there is no admins list to grant from or revoke" do
      for action <- [:list_admins, :grant_admin, :revoke_admin] do
        assert Access.why_not(admin(), action, {:organisation, @org}) == {:error, :not_found}
      end
    end

    test "the system scope answers to nobody" do
      assert Access.can?(Scope.system(@org), :update_settings, {:organisation, @org})
    end
  end

  describe "teams" do
    test "a team the caller is not in does not exist" do
      for s <- [lead(), member(), nobody()] do
        assert Access.why_not(s, :read, {:team, @frontend}) == {:error, :not_found}
      end

      assert Access.can?(admin(), :read, {:team, @frontend})
    end

    test "everyone in the team reads it and its members" do
      for s <- [lead(), member()], action <- [:read, :list_members] do
        assert Access.can?(s, action, {:team, @backend})
      end
    end

    test "a team lead runs the team's settings, invitations and staff; the team and its roles are the system admin's" do
      for action <- [:read_settings, :update_settings, :invite_member, :remove_member] do
        assert Access.can?(lead(), action, {:team, @backend}), "lead #{action}"
      end

      for action <- [:update, :archive, :change_role] do
        assert Access.can?(admin(), action, {:team, @backend})

        assert Access.why_not(lead(), action, {:team, @backend}) ==
                 {:error, {:forbidden, @admin_words}}
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

    test "making a team is the system admin's" do
      assert Access.can?(admin(), :create, {:team, %{}})

      assert Access.why_not(lead(), :create, {:team, %{}}) ==
               {:error, {:forbidden, @admin_words}}
    end
  end

  describe "invitations" do
    test "an admin invitation is nobody's from a route: the bootstrap's alone" do
      for s <- [admin(), lead()] do
        assert {:error, {:forbidden, _words}} =
                 Access.why_not(s, :create, {:invitation, %{kind: :admin}})
      end

      assert Access.can?(Scope.system(@org), :create, {:invitation, %{kind: :admin}})
    end

    test "a team invitation follows invite_member on the team" do
      inv = %{kind: :team_member, team_id: "backend"}

      for s <- [admin(), lead()], do: assert(Access.can?(s, :create, {:invitation, inv}))

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

      for s <- [admin(), lead()], do: assert(Access.can?(s, :create, {:invitation, inv}))

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

    test "reading and revoking: the system admin all, a lead their team's, a member none" do
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

  describe "pipelines (AQ-04A §4.2)" do
    test "every staff member reads; a team lead or the system admin edits; a customer finds nothing" do
      for s <- [admin(), lead(), member()],
          do: assert(Access.can?(s, :read, {:pipeline, :employment}))

      assert Access.can?(admin(), :edit, {:pipeline, :employment})
      assert Access.can?(lead(), :edit, {:pipeline, :freelance})

      assert Access.why_not(member(), :edit, {:pipeline, :employment}) ==
               {:error, {:forbidden, "Only a team lead can change a pipeline."}}

      customer = scope(%{Scope.no_roles() | customer_id: "c1"})
      assert Access.why_not(customer, :read, {:pipeline, :employment}) == {:error, :not_found}
      assert Access.why_not(nobody(), :edit, {:pipeline, :employment}) == {:error, :not_found}
    end
  end

  describe "people and self" do
    test "every staff account reads the staff list; an account with no role does not" do
      for s <- [admin(), lead(), member()], do: assert(Access.can?(s, :read_people, :people))

      assert Access.why_not(nobody(), :read_people, :people) == {:error, :not_found}
    end

    test "everyone reads and updates themselves" do
      for s <- [admin(), member(), nobody()], action <- [:read_self, :update_self] do
        assert Access.can?(s, action, :self)
      end
    end

    test "an unknown action is not found" do
      assert Access.why_not(member(), :fly, :moon) == {:error, :not_found}
    end
  end
end
