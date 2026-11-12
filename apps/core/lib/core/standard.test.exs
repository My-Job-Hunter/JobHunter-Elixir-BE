defmodule Core.StandardTest do
  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Customers
  alias Core.Organisation
  alias Core.Organisation.Invitations
  alias Core.Standard
  alias Core.Standard.Pool
  alias Data.Accounts.User
  alias Data.Audit.AuditEvent
  alias Data.Organisations
  alias Data.Scope

  @now ~U[2026-11-12 09:00:00.000000Z]
  # The worst-list refuses `password123` outside a dev server, so the suite
  # passes a strong one; `mix aq.seed_standard` passes `password123` in dev.
  @password "a standard set for the suite"

  @sources ~w(linkedin indeed upwork wellfound yc_waas greenhouse lever)a

  defp ensure, do: Standard.ensure(Scope.system(), @password, @now)

  defp counts do
    for schema <- [
          User,
          AuditEvent,
          Data.Teams.Team,
          Data.Teams.TeamMember,
          Data.Invitations.Invitation,
          Data.Customers.Customer,
          Data.Customers.Profile,
          Data.Companies.Company,
          Data.Jobs.Job
        ],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  describe "ensure/3 on an empty database" do
    test "makes the organisation, three teams, the ten accounts, three customers and 21 jobs" do
      assert {:ok, %{made: made, kept: 0}} = ensure()
      # 41 rows, then each account's whole label as its given name.
      assert length(made) == 51

      org = Organisations.the_one()
      assert org.name == "Regbits BD"
      assert Organisations.the_admin(org.id).user.email == "super-admin@example.com"

      teams = Data.Teams.list(org.id)
      assert Enum.map(teams, & &1.name) == ["Team 1", "Team 2", "Team 3"]
      team = Map.new(teams, &{&1.name, &1.id})

      for account <- Standard.accounts() do
        user = Data.Accounts.get_user_by_email(account.email)
        assert user, "no account #{account.email}"
        assert user.person.display_name == account.name
        # Words use the given name, so "Team Lead 1" is never cut to "Team".
        assert user.person.given_name == account.name
        assert User.valid_password?(user, @password)

        roles = for m <- Data.Teams.memberships_of(user.id), do: {m.team.name, m.role}
        customer = Data.Customers.get_by_user(user.id)

        case account.role do
          :system_admin ->
            assert {roles, customer} == {[], nil}

          :team_lead ->
            assert {roles, customer} == {[{account.team, :lead}], nil}

          :staff ->
            assert {roles, customer} == {[{account.team, :member}], nil}

          :customer ->
            assert roles == []
            assert customer.status == :active
            assert customer.email == account.email
            assert customer.team_ids == [team[account.team]]
            assert [profile] = Data.Profiles.list(customer.id)
            assert profile.status == :active
            assert profile.title =~ account.name
            [staff] = Enum.map(profile.profile_members, & &1.user.email)
            assert staff == String.replace(account.email, "customer", "staff")
        end
      end

      assert length(Standard.accounts()) == 10
      assert Repo.aggregate(Data.Customers.Customer, :count) == 3

      jobs =
        Repo.all(
          from(j in Data.Jobs.Job,
            where: j.organisation_id == ^org.id,
            preload: [:team, :created_by_user, :company]
          )
        )

      assert length(jobs) == 21
      assert Enum.frequencies_by(jobs, & &1.source) == Map.new(@sources, &{&1, 3})
      assert Enum.frequencies_by(jobs, & &1.team.name) == Map.new(Map.keys(team), &{&1, 7})

      for job <- jobs do
        "Team " <> n = job.team.name
        assert job.created_by_user.email == "team-lead#{n}@example.com"
        assert job.origin == :manual
        assert job.status == :open
        assert job.company.name
        assert {job.comp_min_minor, job.comp_currency, job.comp_period} != {nil, nil, nil}
      end

      # Each link is detected as its board, the way the app detects it.
      for job <- Pool.all() do
        assert {:ok, %{source: source}} = Utils.JobKey.parse(job.url)
        assert to_string(source) == job.source
      end
    end

    test "run twice, the second run makes nothing and writes nothing" do
      assert {:ok, %{made: [_ | _]}} = ensure()
      before = counts()

      assert {:ok, %{made: [], kept: 41}} = ensure()
      assert counts() == before
    end

    test "the rows carry the audit a person would leave" do
      assert {:ok, _summary} = ensure()
      lead = Data.Accounts.get_user_by_email("team-lead2@example.com")

      made_by_lead =
        Repo.all(
          from(e in AuditEvent,
            where: e.actor_user_id == ^lead.id and e.action == "created",
            select: e.subject_kind
          )
        )

      assert Enum.frequencies(made_by_lead)["jobs"] == 7
      assert "customers" in made_by_lead
      assert "profiles" in made_by_lead
      assert Repo.exists?(from(e in AuditEvent, where: e.via == :task))
    end
  end

  describe "ensure/3 on a database that has an organisation" do
    test "keeps the world's organisation when Super Admin is its system admin, and adds the rest" do
      params = %{
        org_name: "Regbits BD",
        admin_email: "super-admin@example.com",
        admin_name: "Super Admin"
      }

      {:ok, %{invitation: invitation}} = Organisation.bootstrap(params, @now)

      {:ok, %{user: admin}} =
        Invitations.accept(invitation.code, %{"name" => "Super Admin", "password" => @password},
          now: @now
        )

      {:ok, _squad} = Organisation.Teams.create(scope_for(admin), %{"name" => "Backend squad"})

      assert {:ok, %{made: made, kept: 2}} = ensure()
      assert length(made) == 49

      names = Enum.map(Data.Teams.list(Organisations.the_one().id), & &1.name)
      assert names == ["Backend squad", "Team 1", "Team 2", "Team 3"]
    end

    test "stops with words when somebody else is the system admin, and makes nothing" do
      org = organisation_fixture(%{name: "Regbits BD", slug: "regbits-bd"})
      _dawud = admin_fixture(org, %{email: "dawud@example.com"})

      assert {:error, words} = ensure()
      assert words =~ "system admin is dawud@example.com, not super-admin@example.com"
      assert words =~ "mix ecto.reset"
      assert words =~ "mix aq.admin --to super-admin@example.com"
      assert Data.Teams.list(org.id) == []
      assert Repo.aggregate(Data.Customers.Customer, :count) == 0
    end

    test "puts back what drifted, through the verbs" do
      assert {:ok, _summary} = ensure()
      admin = Data.Accounts.get_user_by_email("super-admin@example.com")
      customer = Data.Accounts.get_user_by_email("customer1@example.com")
      %{id: id} = Data.Customers.get_by_user(customer.id)

      assert {:ok, %{status: :paused}} =
               Customers.change_status(scope_for(admin), id, "paused", @now)

      assert {:ok, %{made: ["customer1@example.com active"], kept: 41}} = ensure()
      assert Data.Customers.get_by_user(customer.id).status == :active
    end
  end
end
