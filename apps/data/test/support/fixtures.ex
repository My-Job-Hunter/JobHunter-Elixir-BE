defmodule Data.Fixtures do
  @moduledoc """
  Test data (JH-01 §8). **Fixtures take or create a scope**, so it is
  impossible to build test data that could not exist in production: a
  membership always has both sides, an admin always has an organisation, a
  profile always has a customer.

  They write through `Data.*` directly rather than the contexts, so a context
  test does not depend on the thing it tests. `scope_for/1` and
  `customer_scope_for/1` resolve roles the way the plugs do
  (`Core.Access.Grants`, `ApiClient.Plugs.CustomerScope`), but through
  `Data.*` here, because `data` cannot name `core`.
  """

  alias Data.Accounts
  alias Data.Channels
  alias Data.Customers
  alias Data.Documents
  alias Data.Invitations
  alias Data.Invitations.Invitation
  alias Data.Organisations
  alias Data.Profiles
  alias Data.Scope
  alias Data.Skills
  alias Data.Teams

  @password "correct horse battery"
  @today ~D[2026-11-09]

  @doc "A unique email address."
  def unique_email, do: "person#{System.unique_integer([:positive])}@example.com"

  @doc "The password every fixture account has (it passes QP1-6)."
  def valid_password, do: @password

  @doc "An organisation with its default settings."
  def organisation_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, organisation} =
      attrs
      |> Enum.into(%{name: "Org #{n}", slug: "org-#{n}"})
      |> Organisations.create()

    {:ok, _settings} = Organisations.put_settings(organisation.id, %{})
    organisation
  end

  @doc "A person with an account, no roles."
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_email(), display_name: "Test Person", password: @password})
      |> Accounts.register_user()

    user
  end

  @doc "An account that administers `organisation`."
  def admin_fixture(organisation, attrs \\ %{}) do
    user = user_fixture(attrs)

    {:ok, _admin} =
      Organisations.grant_admin(%{
        organisation_id: organisation.id,
        user_id: user.id,
        granted_at: now()
      })

    user
  end

  @doc "A team of `organisation`, with its default settings."
  def team_fixture(organisation, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", organisation_id: organisation.id})
      |> Teams.create()

    {:ok, _settings} = Teams.put_settings(team.id, %{})
    team
  end

  @doc """
  Somebody in `team` as `role` (`:manager`, `:lead` or `:member`): a new
  account unless `user` is given. Answers the user.
  """
  def member_fixture(team, role, user \\ nil) do
    user = user || user_fixture()

    {:ok, _member} =
      Teams.add_member(%{team_id: team.id, user_id: user.id, role: role, joined_at: now()})

    user
  end

  @doc "An open invitation of `organisation`: admin by default; `team:`/`role:` for a team member, `customer:` for a customer."
  def invitation_fixture(organisation, attrs \\ %{}) do
    attrs = Map.new(attrs)
    team = attrs[:team]
    customer = attrs[:customer]

    {:ok, invitation} =
      attrs
      |> Map.drop([:team, :customer])
      |> Enum.into(%{
        organisation_id: organisation.id,
        kind: kind(team, customer),
        code: Invitation.generate_code(),
        email: (customer && customer.email) || unique_email(),
        invited_name: (customer && customer.display_name) || "Invited Person",
        team_id: team && team.id,
        role: if(team, do: attrs[:role] || :member),
        customer_id: customer && customer.id,
        expires_at: DateTime.add(now(), 7, :day)
      })
      |> Invitations.create()

    invitation
  end

  defp kind(nil, nil), do: :admin
  defp kind(_team, nil), do: :team_member
  defp kind(nil, _customer), do: :customer

  # ── Customers (P1.2) ────────────────────────────────────────────────────────

  @doc """
  A customer of `organisation` served by `teams`. `login: true` gives them
  an account (the accepted invitation) and makes them `active`; otherwise
  they are `invited` with no login, like Sara.
  """
  def customer_fixture(organisation, teams \\ [], attrs \\ %{}) do
    attrs = Map.new(attrs)
    n = System.unique_integer([:positive])

    {:ok, customer} =
      attrs
      |> Map.drop([:login])
      |> Enum.into(%{
        organisation_id: organisation.id,
        display_name: "Customer #{n}",
        email: "customer#{n}@example.com"
      })
      |> Customers.create()

    for team <- teams, do: {:ok, _link} = Customers.assign_team(customer, team.id, @today)

    if attrs[:login] do
      user = user_fixture(email: customer.email, display_name: customer.display_name)
      {:ok, _joined} = Customers.attach_login(customer, user.id, @today)
    end

    Customers.reload(customer)
  end

  @doc "A profile of `customer`; `owners:` a list of staff users."
  def profile_fixture(customer, attrs \\ %{}) do
    attrs = Map.new(attrs)
    n = System.unique_integer([:positive])

    {:ok, profile} =
      attrs
      |> Map.drop([:owners])
      |> Enum.into(%{customer_id: customer.id, title: "Profile #{n}"})
      |> Profiles.create()

    :ok = Profiles.put_owners(profile, Enum.map(attrs[:owners] || [], & &1.id), @today)
    Profiles.reload(profile)
  end

  @doc "A channel of `customer`: LinkedIn, operated by the customer, unless said otherwise."
  def channel_fixture(customer, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, channel} =
      attrs
      |> Enum.into(%{
        customer_id: customer.id,
        kind: :linkedin,
        handle: "https://linkedin.com/in/person-#{n}",
        operated_by: :customer
      })
      |> Channels.create()

    channel
  end

  @doc "A document of `profile`: a portfolio link by default (no media to upload)."
  def document_fixture(profile, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, document} =
      attrs
      |> Enum.into(%{
        profile_id: profile.id,
        kind: :portfolio,
        label: "Document #{n}",
        url: "https://example.com/portfolio/#{n}"
      })
      |> Documents.create()

    Documents.reload(document)
  end

  @doc "A skill of `organisation`'s vocabulary."
  def skill_fixture(organisation, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, skill} =
      attrs
      |> Enum.into(%{organisation_id: organisation.id, name: "Skill #{n}", category: "languages"})
      |> Skills.create()

    skill
  end

  # ── Scopes ──────────────────────────────────────────────────────────────────

  @doc """
  The scope the console's plug would build for `user`: the organisation and
  the roles read from `org_admins`, open `team_members`, `customers.user_id`
  and the teams' settings.
  """
  def scope_for(user, opts \\ []) do
    admin_of = Organisations.admin_of(user.id)
    memberships = Teams.memberships_of(user.id)
    customer = Customers.get_by_user(user.id)

    organisation =
      case Keyword.get(opts, :organisation) do
        nil ->
          case admin_of ++
                 Enum.map(memberships, & &1.team.organisation_id) ++
                 List.wrap(customer && customer.organisation_id) do
            [] -> Organisations.the_one()
            [id | _rest] -> Organisations.get(id)
          end

        organisation ->
          organisation
      end

    teams = Map.new(memberships, &{&1.team_id, &1.role})

    %Scope{
      user: user,
      organisation: organisation,
      roles: %{
        admin?: not is_nil(organisation) and organisation.id in admin_of,
        teams: teams,
        customer_id: customer && customer.id,
        team_settings: teams |> Map.keys() |> Teams.settings_for()
      },
      via: :web,
      request_id: Keyword.get(opts, :request_id, "test-request")
    }
  end

  @doc """
  The scope the portal's plug would build for `customer` (who must have a
  login): pinned to them, no staff roles.
  """
  def customer_scope_for(%{user_id: user_id} = customer, opts \\ []) when is_binary(user_id) do
    user = Accounts.get_user(user_id)

    %Scope{
      user: user,
      organisation: Organisations.get(customer.organisation_id),
      roles: %{Scope.no_roles() | customer_id: customer.id},
      via: :web,
      request_id: Keyword.get(opts, :request_id, "test-request")
    }
  end

  defp now, do: DateTime.utc_now()
end
