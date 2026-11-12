defmodule Core.OrganisationTest do
  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Leads.Change
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

      assert %{number: 1} = Data.Pipelines.live(first.organisation.id, :employment)
      assert %{number: 1} = Data.Pipelines.live(first.organisation.id, :freelance)
    end

    test "once the one system admin is there, it refuses: the role is handed on, not invited" do
      args = %{org_name: "Regbits BD", admin_email: "dawud@example.com", admin_name: "Dawud"}
      assert {:ok, %{organisation: org}} = Organisation.bootstrap(args, @now)
      _dawud = admin_fixture(org)

      assert Organisation.bootstrap(%{args | admin_email: "other@example.com"}, @now) ==
               {:error, :admin_exists}
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

    test "the system admin reads Settings › System; a lead and a member are refused in §8.5's words",
         %{org: org, admin: admin, lead: lead, member: member} do
      assert {:ok, %{organisation: %{id: id}, settings: settings}} = Organisation.get(admin)
      assert id == org.id
      assert settings.inactivity_days == 90

      for scope <- [lead, member] do
        assert Organisation.get(scope) ==
                 {:error, {:forbidden, "Only the system admin can do that."}}
      end
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

  describe "the one system admin (QP4a-21)" do
    setup do
      org = organisation_fixture()
      admin = admin_fixture(org)
      team = team_fixture(org)
      %{org: org, admin: admin, team: team, hira: member_fixture(team, :lead)}
    end

    test "a second admin row is refused: one per organisation", %{org: org, hira: hira} do
      assert {:error, changeset} =
               Organisations.grant_admin(%{
                 organisation_id: org.id,
                 user_id: hira.id,
                 granted_at: @now
               })

      assert %{organisation_id: ["already has its system admin"]} = errors_on(changeset)
    end

    test "hand_admin moves the row to an existing staff account, audited", %{
      org: org,
      admin: admin,
      hira: hira
    } do
      system = Data.Scope.system(org)
      assert {:ok, handed} = Organisation.hand_admin(system, String.upcase(hira.email), @now)
      assert handed.user_id == hira.id
      assert Organisations.admin_of(hira.id) == [org.id]
      assert Organisations.admin_of(admin.id) == []

      assert [%{action: "admin_handed", via: :system, before: before, after: after_}] =
               Audit.list_for_subject(org.id, "org_admins", handed.id)

      assert before["user_id"] == admin.id and after_["user_id"] == hira.id

      assert {:ok, same} = Organisation.hand_admin(system, hira.email, @now)
      assert same.id == handed.id
    end

    test "hand_admin refuses an unknown email, a customer's sign-in, and an organisation with no admin yet",
         %{org: org} do
      system = Data.Scope.system(org)
      assert Organisation.hand_admin(system, "nobody@example.com", @now) == {:error, :not_found}

      customer = customer_fixture(org, [], login: true)
      assert Organisation.hand_admin(system, customer.email, @now) == {:error, :customer}

      fresh = organisation_fixture()

      assert Organisation.hand_admin(Data.Scope.system(fresh), customer.email, @now) ==
               {:error, :no_admin}
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
      lead = member_fixture(backend, :lead)

      %{
        org: org,
        admin: scope_for(admin),
        lead: scope_for(lead),
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

    test "a team lead or a member cannot read it: the system admin's alone", %{
      lead: lead,
      backend: backend
    } do
      assert Organisation.list_audit(lead, %{}) ==
               {:error, {:forbidden, "Only the system admin can do that."}}

      assert {:error, {:forbidden, _words}} =
               Organisation.list_audit(scope_for(member_fixture(backend, :member)), %{})
    end
  end

  describe "Customer › Activity (AQ-04B QP4b-22)" do
    test "the system admin, every row; a team lead, their teams' rows; staff not found" do
      c = board_cast_fixture()

      {:ok, _} =
        Core.Customers.assign_team(
          scope_for(c.dawud),
          c.tanweer.id,
          c.frontend.id,
          DateTime.utc_now()
        )

      backend = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
      frontend = lead_fixture(scope_for(c.hira), team: c.frontend, profile: c.golang)

      for {who, lead} <- [{c.fiza, backend}, {c.hira, frontend}],
          do: {:ok, _} = Change.flag(scope_for(who), :pin, lead.id, DateTime.utc_now())

      subjects = fn scope ->
        {:ok, events, _cursor} = Organisation.customer_activity(scope, c.tanweer.id, %{})

        events
        |> Enum.filter(&(&1.subject_kind == "leads"))
        |> Enum.map(& &1.subject_id)
        |> Enum.sort()
      end

      assert subjects.(scope_for(c.dawud)) == Enum.sort([backend.id, frontend.id])
      assert subjects.(scope_for(c.bilal)) == [backend.id]
      assert subjects.(scope_for(c.hira)) == Enum.sort([backend.id, frontend.id])

      {:ok, all, _} = Organisation.customer_activity(scope_for(c.dawud), c.tanweer.id, %{})
      assert Enum.any?(all, &(&1.subject_kind == "customers"))

      for who <- [c.fiza, c.muaz],
          do:
            assert(
              Organisation.customer_activity(scope_for(who), c.tanweer.id, %{}) ==
                {:error, :not_found}
            )

      assert Organisation.customer_activity(customer_scope_for(c.tanweer), c.tanweer.id, %{}) ==
               {:error, :not_found}

      assert Organisation.customer_activity(scope_for(c.bilal), c.imran.id, %{}) ==
               {:error, :not_found}
    end
  end
end
