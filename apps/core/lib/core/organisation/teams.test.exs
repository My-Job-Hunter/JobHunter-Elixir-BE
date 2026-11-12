defmodule Core.Organisation.TeamsTest do
  use Core.CoreCase, async: true

  alias Core.Organisation.Teams
  alias Data.Audit

  @now ~U[2026-11-09 10:00:00.000000Z]
  @admin_words "Only the system admin can do that."

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    other_lead = member_fixture(backend, :lead)
    lead = member_fixture(backend, :lead)
    member = member_fixture(backend, :member)

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: scope_for(admin),
      lead: scope_for(lead),
      member: scope_for(member),
      other_lead_user: other_lead,
      lead_user: lead,
      member_user: member
    }
  end

  describe "teams" do
    test "list: all for the system admin, own for everyone else", %{
      admin: admin,
      lead: lead,
      member: member,
      backend: backend
    } do
      assert {:ok, teams} = Teams.list(admin)
      assert length(teams) == 2
      assert {:ok, [%{id: lead_team}]} = Teams.list(lead)
      assert {:ok, [%{id: member_team}]} = Teams.list(member)
      assert lead_team == backend.id and member_team == backend.id
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

    test "create: by the system admin, with default settings, audited; a team lead is refused in §8.5's words",
         %{org: org, admin: admin, lead: lead} do
      assert {:ok, team} = Teams.create(admin, %{"name" => "Data squad"})
      assert team.slug == "data-squad"

      assert %{peer_tasks: :view, peer_leads: :view, peer_jobs: :edit} =
               Data.Teams.get_settings(team.id)

      assert [%{action: "created", after: %{"name" => "Data squad"}}] =
               Audit.list_for_subject(org.id, "teams", team.id)

      assert {:error, %Ecto.Changeset{}} = Teams.create(admin, %{"name" => "Data squad"})
      assert {:error, %Ecto.Changeset{}} = Teams.create(admin, %{"name" => ""})
      assert Teams.create(lead, %{"name" => "Another"}) == {:error, {:forbidden, @admin_words}}
    end

    test "update and archive: the system admin yes, a team lead no, audited", %{
      org: org,
      admin: admin,
      lead: lead,
      backend: backend
    } do
      assert {:ok, updated} = Teams.update(admin, backend.id, %{"name" => "Backend"})
      assert updated.name == "Backend"

      assert Teams.update(lead, backend.id, %{"name" => "Nope"}) ==
               {:error, {:forbidden, @admin_words}}

      assert Teams.archive(lead, backend.id, @now) == {:error, {:forbidden, @admin_words}}

      assert {:ok, archived} = Teams.archive(admin, backend.id, @now)
      assert archived.archived_at == @now
      assert {:ok, []} = Teams.list(scope_for(lead.user))
      rows = Audit.list_for_subject(org.id, "teams", backend.id)
      assert Enum.sort(Enum.map(rows, & &1.action)) == ["archived", "updated"]
      assert Enum.find(rows, &(&1.action == "updated")).before["name"] == "Backend squad"
    end
  end

  describe "settings" do
    test "read and written by a team lead, audited with the team named", %{
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

    test "the three levels: any subset, audited before and after; a level off the list is a field error",
         %{org: org, lead: lead, backend: backend} do
      assert {:ok, settings} =
               Teams.put_settings(lead, backend.id, %{
                 "peer_tasks" => "hidden",
                 "peer_jobs" => "view"
               })

      assert {settings.peer_tasks, settings.peer_leads, settings.peer_jobs} ==
               {:hidden, :view, :view}

      assert [%{before: before, after: after_map}] =
               Audit.list_for_subject(org.id, "team_settings", backend.id)

      assert {before["peer_tasks"], after_map["peer_tasks"]} == {"view", "hidden"}

      assert {:error, %Ecto.Changeset{} = cs} =
               Teams.put_settings(lead, backend.id, %{"peer_leads" => "sometimes"})

      assert cs.errors[:peer_leads]
    end
  end

  describe "members" do
    test "listed by anyone in the team, with their people", %{
      member: member,
      backend: backend,
      frontend: frontend
    } do
      assert {:ok, members} = Teams.list_members(member, backend.id)
      assert Enum.map(members, & &1.role) |> Enum.sort() == [:lead, :lead, :member]
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

    test "change_role is the system admin's: lead and back, audited; a team lead is refused", %{
      org: org,
      admin: admin,
      lead: lead,
      backend: backend,
      member_user: member_user
    } do
      assert Teams.change_role(lead, backend.id, member_user.id, "lead") ==
               {:error, {:forbidden, @admin_words}}

      assert {:ok, changed} = Teams.change_role(admin, backend.id, member_user.id, "lead")
      assert changed.role == :lead
      assert {:ok, changed} = Teams.change_role(admin, backend.id, member_user.id, "member")
      assert changed.role == :member

      assert [
               %{
                 action: "role_changed",
                 before: %{"role" => "member"},
                 after: %{"role" => "lead"}
               },
               _back
             ] =
               Audit.list_for_subject(org.id, "team_members", changed.id)
    end

    test "no manager role; an unknown role and a member who is not there are refused", %{
      admin: admin,
      backend: backend,
      member_user: member_user
    } do
      assert Teams.change_role(admin, backend.id, member_user.id, "manager") ==
               {:error, {:missing, :role}}

      assert Teams.change_role(admin, backend.id, Ecto.UUID.generate(), "member") ==
               {:error, :not_found}
    end

    test "a team lead removes staff of their team, never another lead", %{
      lead: lead,
      backend: backend,
      other_lead_user: other_lead,
      member_user: member_user
    } do
      assert Teams.remove_member(lead, backend.id, other_lead.id, @now) ==
               {:error, {:forbidden, @admin_words}}

      assert Teams.remove_member(lead, backend.id, member_user.id, @now) == :ok
    end

    test "a member may change nobody", %{member: member, backend: backend, lead_user: lead_user} do
      assert {:error, {:forbidden, _words}} =
               Teams.change_role(member, backend.id, lead_user.id, "member")

      assert {:error, {:forbidden, _words}} =
               Teams.remove_member(member, backend.id, lead_user.id, @now)
    end

    test "remove_member ends the membership and audits it", %{
      org: org,
      admin: admin,
      backend: backend,
      member_user: member_user
    } do
      membership = Data.Teams.get_open_member(backend.id, member_user.id)
      assert Teams.remove_member(admin, backend.id, member_user.id, @now) == :ok
      assert Data.Teams.get_open_member(backend.id, member_user.id) == nil
      assert Repo.get!(Data.Teams.TeamMember, membership.id).left_at == @now

      assert [%{action: "removed"}] =
               Audit.list_for_subject(org.id, "team_members", membership.id)

      assert Teams.remove_member(admin, backend.id, member_user.id, @now) ==
               {:error, :not_found}
    end

    test "the team keeps a lead while it has members", %{org: org, admin: admin} do
      team = team_fixture(org)
      only_lead = member_fixture(team, :lead)
      member = member_fixture(team, :member)

      assert {:error, {:forbidden, words}} =
               Teams.remove_member(admin, team.id, only_lead.id, @now)

      assert words =~ "needs a lead"

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
