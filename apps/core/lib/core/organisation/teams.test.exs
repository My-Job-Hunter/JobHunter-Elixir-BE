defmodule Core.Organisation.TeamsTest do
  use Core.CoreCase, async: true

  alias Core.Organisation.Teams
  alias Data.Audit

  @now ~U[2026-11-09 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    manager = member_fixture(backend, :manager)
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: scope_for(admin),
      manager: scope_for(manager),
      lead: scope_for(lead),
      member: scope_for(member),
      manager_user: manager,
      lead_user: lead,
      member_user: member
    }
  end

  describe "teams" do
    test "list: all for an admin or a manager, own for others", %{
      admin: admin,
      manager: manager,
      member: member,
      backend: backend
    } do
      assert {:ok, teams} = Teams.list(admin)
      assert length(teams) == 2
      assert {:ok, teams} = Teams.list(manager)
      assert length(teams) == 2
      assert {:ok, [%{id: id}]} = Teams.list(member)
      assert id == backend.id
    end

    test "get: a team the caller is not in does not exist", %{
      member: member,
      frontend: frontend,
      backend: backend
    } do
      assert {:ok, %{id: id}} = Teams.get(member, backend.id)
      assert id == backend.id
      assert Teams.get(member, frontend.id) == {:error, :not_found}
      assert Teams.get(member, "nonsense") == {:error, :not_found}
    end

    test "create: by an admin or a manager, with default settings, audited; a lead may not", %{
      org: org,
      manager: manager,
      lead: lead
    } do
      assert {:ok, team} = Teams.create(manager, %{"name" => "Data squad"})
      assert team.slug == "data-squad"
      assert Data.Teams.get_settings(team.id).members_see_peer_leads == true

      assert [%{action: "created", after: %{"name" => "Data squad"}}] =
               Audit.list_for_subject(org.id, "teams", team.id)

      assert {:error, %Ecto.Changeset{}} = Teams.create(manager, %{"name" => "Data squad"})
      assert {:error, %Ecto.Changeset{}} = Teams.create(manager, %{"name" => ""})
      assert {:error, {:forbidden, _words}} = Teams.create(lead, %{"name" => "Another"})
    end

    test "update and archive: a manager yes, a lead no, audited", %{
      org: org,
      manager: manager,
      lead: lead,
      backend: backend
    } do
      assert {:ok, updated} = Teams.update(manager, backend.id, %{"name" => "Backend"})
      assert updated.name == "Backend"
      assert {:error, {:forbidden, _words}} = Teams.update(lead, backend.id, %{"name" => "Nope"})

      assert {:ok, archived} = Teams.archive(manager, backend.id, @now)
      assert archived.archived_at == @now
      assert {:ok, []} = Teams.list(scope_for(lead.user))
      rows = Audit.list_for_subject(org.id, "teams", backend.id)
      assert Enum.sort(Enum.map(rows, & &1.action)) == ["archived", "updated"]
      assert Enum.find(rows, &(&1.action == "updated")).before["name"] == "Backend squad"
    end
  end

  describe "settings" do
    test "read and written by a lead or above, audited with the team named", %{
      org: org,
      lead: lead,
      member: member,
      backend: backend
    } do
      assert {:ok, settings} = Teams.get_settings(lead, backend.id)
      assert settings.customer_sees_staff_names == true
      assert {:error, {:forbidden, _words}} = Teams.get_settings(member, backend.id)

      assert {:ok, settings} =
               Teams.put_settings(lead, backend.id, %{"customer_sees_staff_names" => false})

      assert settings.customer_sees_staff_names == false

      assert [
               %{
                 action: "updated",
                 before: %{"customer_sees_staff_names" => true},
                 after: after_map
               }
             ] =
               Audit.list_for_subject(org.id, "team_settings", backend.id)

      assert after_map["team_id"] == backend.id

      assert {:error, {:forbidden, _words}} =
               Teams.put_settings(member, backend.id, %{"customer_sees_staff_names" => true})
    end
  end

  describe "members" do
    test "listed by anyone in the team, with their people", %{
      member: member,
      backend: backend,
      frontend: frontend
    } do
      assert {:ok, members} = Teams.list_members(member, backend.id)
      assert Enum.map(members, & &1.role) |> Enum.sort() == [:lead, :manager, :member]
      assert Enum.all?(members, & &1.user.person.display_name)
      assert Teams.list_members(member, frontend.id) == {:error, :not_found}
    end

    test "add_member keeps an open membership as it is, and audits a new one", %{
      org: org,
      admin: admin,
      backend: backend,
      lead_user: lead
    } do
      assert {:ok, same} = Teams.add_member(admin, backend, lead, :member, @now)
      assert same.role == :lead

      newcomer = user_fixture()
      assert {:ok, joined} = Teams.add_member(admin, backend, newcomer, :member, @now)
      assert joined.role == :member

      assert [%{action: "joined", after: %{"team_id" => team_id}}] =
               Audit.list_for_subject(org.id, "team_members", joined.id)

      assert team_id == backend.id
    end

    test "change_role: a manager promotes to manager; a lead may not (role_above_yours)", %{
      org: org,
      manager: manager,
      lead: lead,
      backend: backend,
      member_user: member_user
    } do
      assert {:error, :role_above_yours} =
               Teams.change_role(lead, backend.id, member_user.id, "manager")

      assert {:ok, changed} = Teams.change_role(lead, backend.id, member_user.id, "lead")
      assert changed.role == :lead
      assert {:ok, changed} = Teams.change_role(manager, backend.id, member_user.id, "manager")
      assert changed.role == :manager

      assert [
               %{
                 action: "role_changed",
                 before: %{"role" => "member"},
                 after: %{"role" => "lead"}
               },
               _second
             ] =
               Audit.list_for_subject(org.id, "team_members", changed.id)
    end

    test "a lead cannot touch a manager, nor an unknown role, nor a member who is not there", %{
      lead: lead,
      backend: backend,
      manager_user: manager_user
    } do
      assert Teams.change_role(lead, backend.id, manager_user.id, "member") ==
               {:error, :role_above_yours}

      assert Teams.remove_member(lead, backend.id, manager_user.id, @now) ==
               {:error, :role_above_yours}

      assert Teams.change_role(lead, backend.id, Ecto.UUID.generate(), "member") ==
               {:error, :not_found}

      assert Teams.change_role(lead, backend.id, manager_user.id, "boss") ==
               {:error, {:missing, :role}}
    end

    test "a member may change nobody", %{member: member, backend: backend, lead_user: lead_user} do
      assert {:error, {:forbidden, _words}} =
               Teams.change_role(member, backend.id, lead_user.id, "member")

      assert {:error, {:forbidden, _words}} =
               Teams.remove_member(member, backend.id, lead_user.id, @now)
    end

    test "remove_member ends the membership and audits it", %{
      org: org,
      manager: manager,
      backend: backend,
      member_user: member_user
    } do
      membership = Data.Teams.get_open_member(backend.id, member_user.id)
      assert Teams.remove_member(manager, backend.id, member_user.id, @now) == :ok
      assert Data.Teams.get_open_member(backend.id, member_user.id) == nil
      assert Repo.get!(Data.Teams.TeamMember, membership.id).left_at == @now

      assert [%{action: "removed"}] =
               Audit.list_for_subject(org.id, "team_members", membership.id)

      assert Teams.remove_member(manager, backend.id, member_user.id, @now) ==
               {:error, :not_found}
    end

    test "the team keeps a lead or a manager while it has members", %{org: org, admin: admin} do
      team = team_fixture(org)
      only_lead = member_fixture(team, :lead)
      member = member_fixture(team, :member)

      assert {:error, {:forbidden, words}} =
               Teams.remove_member(admin, team.id, only_lead.id, @now)

      assert words =~ "lead or a manager"

      assert {:error, {:forbidden, _words}} =
               Teams.change_role(admin, team.id, only_lead.id, "member")

      # Promote the member first, then the lead may step down or go.
      assert {:ok, _changed} = Teams.change_role(admin, team.id, member.id, "lead")
      assert {:ok, _changed} = Teams.change_role(admin, team.id, only_lead.id, "member")
      assert Teams.remove_member(admin, team.id, only_lead.id, @now) == :ok

      # The last person may always leave: an empty team needs no lead.
      assert Teams.remove_member(admin, team.id, member.id, @now) == :ok
      assert Data.Teams.list_members(team.id) == []
    end
  end
end
