defmodule Core.OrganisationTest do
  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Organisation
  alias Data.Audit
  alias Data.Organisations

  @now ~U[2026-11-09 10:00:00.000000Z]

  describe "bootstrap" do
    test "creates the organisation with its settings and an admin invitation, and is idempotent" do
      args = %{
        org_name: "Regbits BD",
        admin_email: "dawud@example.com",
        admin_name: "Dawud Kalim"
      }

      assert {:ok, first} = Organisation.bootstrap(args, @now)
      assert first.organisation_created?
      assert first.status == :issued
      assert first.organisation.slug == "regbits-bd"
      assert first.invitation.kind == :admin
      assert first.invitation.email == "dawud@example.com"
      assert first.invitation.expires_at == DateTime.add(@now, 7, :day)
      assert Organisations.get_settings(first.organisation.id).follow_up_gap_days == 3

      assert [%{action: "created", via: :system, actor_user_id: nil}] =
               Audit.list_for_subject(
                 first.organisation.id,
                 "organisations",
                 first.organisation.id
               )

      assert [_job] = all_enqueued(worker: Notifire.Workers.InvitationWorker)

      assert {:ok, second} = Organisation.bootstrap(args, @now)
      refute second.organisation_created?
      assert second.status == :open
      assert second.invitation.id == first.invitation.id

      later = DateTime.add(@now, 8, :day)
      assert {:ok, third} = Organisation.bootstrap(args, later)
      assert third.status == :reissued
      assert third.invitation.id == first.invitation.id
      assert third.invitation.expires_at == DateTime.add(later, 7, :day)
    end
  end

  describe "the organisation and its settings" do
    setup do
      org = organisation_fixture()
      team = team_fixture(org)

      %{
        org: org,
        admin: scope_for(admin_fixture(org)),
        lead: scope_for(member_fixture(team, :lead)),
        member: scope_for(member_fixture(team, :member))
      }
    end

    test "a lead reads, a member does not", %{org: org, lead: lead, member: member} do
      assert {:ok, %{organisation: %{id: id}, settings: settings}} = Organisation.get(lead)
      assert id == org.id
      assert settings.inactivity_days == 90
      assert {:error, {:forbidden, _words}} = Organisation.get(member)
    end

    test "an admin writes the timings and the organisation's own fields, audited; ranges hold", %{
      org: org,
      admin: admin,
      lead: lead
    } do
      assert {:ok, %{settings: settings, organisation: organisation}} =
               Organisation.update_settings(admin, %{
                 "follow_up_gap_days" => 5,
                 "timezone" => "Asia/Dubai",
                 "name" => "Regbits"
               })

      assert settings.follow_up_gap_days == 5
      assert organisation.timezone == "Asia/Dubai"

      assert [
               %{
                 action: "updated",
                 before: %{"follow_up_gap_days" => 3},
                 after: %{"follow_up_gap_days" => 5}
               }
             ] =
               Audit.list_for_subject(org.id, "organisation_settings", org.id)

      assert [%{action: "updated", after: %{"name" => "Regbits"}}] =
               Audit.list_for_subject(org.id, "organisations", org.id)

      assert {:error, %Ecto.Changeset{}} =
               Organisation.update_settings(admin, %{"inactivity_days" => 0})

      assert {:error, %Ecto.Changeset{}} =
               Organisation.update_settings(admin, %{"warning_days" => 400})

      assert {:error, {:forbidden, _words}} =
               Organisation.update_settings(lead, %{"warning_days" => 2})
    end
  end

  describe "admins" do
    setup do
      org = organisation_fixture()
      admin = admin_fixture(org)
      team = team_fixture(org)

      %{
        org: org,
        admin: admin,
        scope: scope_for(admin),
        team: team,
        manager: member_fixture(team, :manager)
      }
    end

    test "granting and revoking, audited", %{org: org, scope: scope, manager: manager} do
      assert {:ok, granted} = Organisation.grant_admin(scope, manager.id, @now)
      assert granted.user_id == manager.id
      assert granted.granted_by_user_id == scope.user.id
      assert {:ok, admins} = Organisation.list_admins(scope)
      assert length(admins) == 2
      assert [%{action: "granted"}] = Audit.list_for_subject(org.id, "org_admins", granted.id)

      assert Organisation.grant_admin(scope, manager.id, @now) == {:error, :conflict}
      assert Organisation.grant_admin(scope, Ecto.UUID.generate(), @now) == {:error, :not_found}

      assert Organisation.revoke_admin(scope, manager.id, @now) == :ok
      assert {:ok, [_one]} = Organisation.list_admins(scope)

      assert [_granted, %{action: "revoked"}] =
               Audit.list_for_subject(org.id, "org_admins", granted.id)

      assert Organisation.revoke_admin(scope, manager.id, @now) == {:error, :not_found}
    end

    test "the last admin cannot be removed", %{admin: admin, scope: scope} do
      assert Organisation.revoke_admin(scope, admin.id, @now) == {:error, :last_admin}
    end

    test "only an admin touches the admin list", %{manager: manager, admin: admin} do
      scope = scope_for(manager)
      assert {:error, {:forbidden, _words}} = Organisation.list_admins(scope)
      assert {:error, {:forbidden, _words}} = Organisation.grant_admin(scope, manager.id, @now)
      assert {:error, {:forbidden, _words}} = Organisation.revoke_admin(scope, admin.id, @now)
    end
  end

  describe "people" do
    setup do
      org = organisation_fixture()
      backend = team_fixture(org, name: "Backend")
      frontend = team_fixture(org, name: "Frontend")
      hira = member_fixture(backend, :lead)
      member_fixture(frontend, :lead, hira)
      fiza = member_fixture(frontend, :member)
      admin = admin_fixture(org)
      %{org: org, backend: backend, frontend: frontend, hira: hira, fiza: fiza, admin: admin}
    end

    test "an admin sees everyone, with teams, roles and the admin mark", %{
      admin: admin,
      hira: hira,
      fiza: fiza
    } do
      {:ok, people} = Organisation.list_people(scope_for(admin))
      by_id = Map.new(people, &{&1.user_id, &1})

      assert Map.keys(by_id) |> Enum.sort() == Enum.sort([admin.id, hira.id, fiza.id])
      assert by_id[admin.id].is_admin and by_id[admin.id].teams == []
      assert Enum.map(by_id[hira.id].teams, & &1.role) == [:lead, :lead]
      assert by_id[fiza.id].email == fiza.email
    end

    test "a member sees their own team only; a team filter narrows", %{
      fiza: fiza,
      hira: hira,
      admin: admin,
      backend: backend
    } do
      {:ok, people} = Organisation.list_people(scope_for(fiza))
      assert Enum.map(people, & &1.user_id) |> Enum.sort() == Enum.sort([fiza.id, hira.id])

      {:ok, people} = Organisation.list_people(scope_for(admin), %{"team_id" => backend.id})
      assert Enum.map(people, & &1.user_id) == [hira.id]
    end

    test "an account with no role sees nobody" do
      assert Organisation.list_people(scope_for(user_fixture())) == {:error, :not_found}
    end
  end

  describe "the audit log" do
    setup do
      org = organisation_fixture()
      admin = admin_fixture(org)
      backend = team_fixture(org)
      other = team_fixture(org)
      manager = member_fixture(backend, :manager)

      %{
        org: org,
        admin: scope_for(admin),
        manager: scope_for(manager),
        backend: backend,
        other: other
      }
    end

    test "an admin pages through everything, newest first, by keyset", %{
      org: org,
      admin: admin,
      backend: backend
    } do
      for n <- 1..55 do
        Core.Audit.record(admin, "updated", backend, now: DateTime.add(@now, n, :second))
      end

      assert {:ok, page, cursor} = Organisation.list_audit(admin, %{})
      assert length(page) == 50
      assert hd(page).occurred_at == DateTime.add(@now, 55, :second)
      assert cursor

      assert {:ok, rest, nil} = Organisation.list_audit(admin, %{"cursor" => cursor})
      assert length(rest) >= 5

      assert Enum.all?(
               rest,
               &(DateTime.compare(&1.occurred_at, List.last(page).occurred_at) != :gt)
             )

      assert org.id == hd(page).organisation_id
    end

    test "filters by subject, actor and time", %{
      org: org,
      admin: admin,
      backend: backend,
      other: other
    } do
      Core.Audit.record(admin, "updated", backend, now: @now)
      Core.Audit.record(admin, "updated", other, now: DateTime.add(@now, 1, :hour))
      _team_rows = Data.Audit.list_for_subject(org.id, "teams", backend.id)

      assert {:ok, [one], nil} =
               Organisation.list_audit(admin, %{
                 "subject_kind" => "teams",
                 "subject_id" => backend.id
               })

      assert one.subject_id == backend.id

      assert {:ok, [_only], nil} =
               Organisation.list_audit(admin, %{
                 "from" => DateTime.to_iso8601(DateTime.add(@now, 30, :minute))
               })

      assert {:ok, [], nil} = Organisation.list_audit(admin, %{"actor" => Ecto.UUID.generate()})

      assert Organisation.list_audit(admin, %{"from" => "yesterday"}) ==
               {:error, {:missing, :from}}
    end

    test "a manager reads rows about their own teams only", %{
      admin: admin,
      manager: manager,
      backend: backend,
      other: other
    } do
      Core.Audit.record(admin, "updated", backend, now: @now)
      Core.Audit.record(admin, "updated", other, now: @now)

      Core.Audit.record(admin, "joined", %Data.Teams.TeamMember{id: Ecto.UUID.generate()},
        after: %{"team_id" => other.id},
        now: @now
      )

      Core.Audit.record(admin, "joined", %Data.Teams.TeamMember{id: Ecto.UUID.generate()},
        after: %{"team_id" => backend.id},
        now: @now
      )

      assert {:ok, rows, nil} = Organisation.list_audit(manager, %{})
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.subject_id == backend.id or &1.after["team_id"] == backend.id))
    end

    test "a lead or member cannot read it", %{backend: backend} do
      assert {:error, {:forbidden, _words}} =
               Organisation.list_audit(scope_for(member_fixture(backend, :lead)), %{})
    end
  end
end
