defmodule Data.Fixtures do
  @moduledoc """
  Test data (AQ-01 §8). **Fixtures take or create a scope**, so test data
  that could not exist in production cannot be built: a membership has both
  sides, an admin an organisation, a profile a customer. They write through
  `Data.*` rather than the contexts, so a context test does not depend on
  the thing it tests; `scope_for/1` and `customer_scope_for/1` resolve roles
  as the plugs do (`Core.Access.Grants`, `ApiClient.Plugs.CustomerScope`),
  through `Data.*`, because `data` cannot name `core`.
  """

  alias Data.Accounts
  alias Data.Channels
  alias Data.Customers
  alias Data.Documents
  alias Data.Fixtures.Notifications, as: Notices
  alias Data.Invitations
  alias Data.Invitations.Invitation
  alias Data.Organisations
  alias Data.Profiles
  alias Data.Repo
  alias Data.Scope
  alias Data.Skills
  alias Data.TaskComments
  alias Data.TaskParts
  alias Data.Tasks
  alias Data.Tasks.Participant
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
  Somebody in `team` as `role` (`:lead` or `:member`): a new
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
      |> Map.drop([:login, :login_name])
      |> Enum.into(%{
        organisation_id: organisation.id,
        display_name: "Customer #{n}",
        email: "customer#{n}@example.com"
      })
      |> Customers.create()

    for team <- teams, do: {:ok, _link} = Customers.assign_team(customer, team.id, @today)

    if attrs[:login] do
      # `login_name:` names the account apart from the customer, as people sign up.
      name = attrs[:login_name] || customer.display_name
      user = user_fixture(email: customer.email, display_name: name)
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

  # ── The board (AQ-02 §11) ───────────────────────────────────────────────────

  @doc """
  The P1 cast (PLAN §17) for a board test: Backend and Frontend squads;
  Dawud the system admin, in no team (AQ-04A §4.0); Hira lead of both; Bilal lead of
  Backend; Fiza member of both; Qasim and Muaz members of Backend;
  Tanweer, Naveed (Backend) and Imran (Frontend) signed in; Sara (Backend)
  invited only; Tanweer's *Golang backend* profile owned by Fiza, then Qasim.
  """
  def board_cast_fixture do
    org = organisation_fixture(name: "Regbits BD")
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    dawud = admin_fixture(org, display_name: "Dawud Kalim")
    hira = member_fixture(backend, :lead, user_fixture(display_name: "Hira Khan"))
    member_fixture(frontend, :lead, hira)
    bilal = member_fixture(backend, :lead, user_fixture(display_name: "Bilal"))
    fiza = member_fixture(backend, :member, user_fixture(display_name: "Fiza"))
    member_fixture(frontend, :member, fiza)
    qasim = member_fixture(backend, :member, user_fixture(display_name: "Qasim"))
    muaz = member_fixture(backend, :member, user_fixture(display_name: "Muaz"))

    tanweer =
      customer_fixture(org, [backend],
        display_name: "Tanweer",
        login: true,
        login_name: "Muhammad Tanweer"
      )

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      dawud: dawud,
      hira: hira,
      bilal: bilal,
      fiza: fiza,
      qasim: qasim,
      muaz: muaz,
      tanweer: tanweer,
      naveed: customer_fixture(org, [backend], display_name: "Naveed", login: true),
      imran: customer_fixture(org, [frontend], display_name: "Imran", login: true),
      sara: customer_fixture(org, [backend], display_name: "Sara"),
      golang: profile_fixture(tanweer, title: "Golang backend", owners: [fiza, qasim])
    }
  end

  @doc """
  A task written by `scope`'s person (or, from a portal scope, the
  customer's own: `source: :customer`, shared). Every task is in a team
  (AQ-03B): `team:`, else the scope's first team by name (a customer's: the
  first team serving them). Attrs are the columns, plus `customer:`, `profile:` (structs), `primary:` and `secondary:`
  (users), `watchers:` (users), `checklist:` (texts) and a `state:` of any
  of the six — each with the columns it needs.
  """
  def task_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    state = attrs[:state] || :todo
    base = task_base(scope, attrs, state)

    {:ok, task} =
      attrs
      |> Map.drop([
        :team,
        :customer,
        :profile,
        :primary,
        :secondary,
        :watchers,
        :checklist,
        :state
      ])
      |> then(&Map.merge(base, &1))
      |> Tasks.create()

    :ok = Tasks.put_assignees(task, attrs[:primary] && attrs[:primary].id, ids(attrs[:secondary]))

    for watcher <- List.wrap(attrs[:watchers]),
        do: Tasks.put_flag(task, watcher.id, :is_watcher, true)

    for text <- List.wrap(attrs[:checklist]), do: {:ok, _item} = TaskParts.add_item(task.id, text)

    task |> Tasks.reload() |> put_state(state, Scope.user_id(scope))
  end

  defp task_base(scope, attrs, state) do
    customer? = not is_nil(Scope.customer_id(scope))

    %{
      organisation_id: Scope.organisation_id(scope),
      author_user_id: Scope.user_id(scope),
      title: "Task #{System.unique_integer([:positive])}",
      source: if(customer?, do: :customer, else: :staff),
      customer_access: if(customer?, do: :shared, else: :none),
      customer_id: id_of(attrs[:customer]) || Scope.customer_id(scope),
      team_id: id_of(attrs[:team]) || default_team(scope),
      profile_id: id_of(attrs[:profile]),
      state: if(state == :draft, do: :draft, else: :todo)
    }
  end

  @doc """
  The team a fixture lands in when none is named: the scope's first team by
  name; for a portal scope, the first team serving the customer. Raises for
  a scope in no team (an admin outside every team must name one).
  """
  def default_team(%Scope{} = scope) do
    ids =
      case Scope.customer_id(scope) do
        nil -> Scope.team_ids(scope)
        id -> Customers.get(Scope.organisation_id(scope), id).team_ids
      end

    case ids != [] && Teams.list(Scope.organisation_id(scope), ids: ids) do
      [team | _rest] -> team.id
      _none -> raise ArgumentError, "this scope is in no team: name one with team:"
    end
  end

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  defp ids(nil), do: []
  defp ids(users), do: Enum.map(users, & &1.id)

  defp put_state(task, state, _user_id) when state in [:draft, :todo], do: task

  defp put_state(task, state, user_id) do
    at = now()

    extra =
      case state do
        :in_progress -> %{}
        :on_hold -> %{held_at: at, hold_reason: "Waiting", held_from_state: :todo}
        :done -> %{done_at: at, done_by_user_id: user_id}
        :closed -> %{closed_at: at, closed_reason: :not_needed, closed_by_user_id: user_id}
      end

    {:ok, moved} = Tasks.move(task, Map.put(extra, :state, state))
    moved
  end

  @doc "A participant row: `level:` (`:primary`, `:secondary`), `is_watcher:`, `is_muted:`."
  def participant_fixture(task, user, attrs \\ %{}) do
    %Participant{}
    |> Participant.changeset(Map.merge(%{task_id: task.id, user_id: user.id}, Map.new(attrs)))
    |> Repo.insert!()
  end

  @doc "A step of `task`: `assignee:` a user, or `is_for_customer: true`."
  def step_fixture(task, attrs \\ %{}) do
    attrs = Map.new(attrs)
    n = System.unique_integer([:positive])

    {:ok, step} =
      TaskParts.add_step(task.id, %{
        title: attrs[:title] || "Step #{n}",
        assignee_user_id: attrs[:assignee] && attrs[:assignee].id,
        is_for_customer: attrs[:is_for_customer] || false
      })

    step
  end

  @doc "A comment on `task` by `scope`'s person; staff-only when `staff_only?`."
  def comment_fixture(%Scope{} = scope, task, staff_only? \\ false) do
    {:ok, comment} =
      TaskComments.create_comment(%{
        task_id: task.id,
        author_user_id: Scope.user_id(scope),
        body: "Comment #{System.unique_integer([:positive])}",
        is_staff_only: staff_only?
      })

    comment
  end

  # ── The pool, leads, the extension, P6, P7, P8 (AQ-03 §11 … AQ-08 §14): their own files

  defdelegate company_fixture(organisation, attrs \\ %{}), to: Data.Fixtures.Jobs
  defdelegate job_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Jobs
  defdelegate in_team(params, scope), to: Data.Fixtures.Jobs
  defdelegate pipeline_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Leads
  defdelegate lead_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Leads
  defdelegate note_fixture(scope, lead, attrs \\ %{}), to: Data.Fixtures.Leads
  defdelegate label_fixture(scope, team, attrs \\ %{}), to: Data.Fixtures.Leads
  defdelegate fingerprint_fixture(scope, job, profile, attrs \\ %{}), to: Data.Fixtures.Leads
  defdelegate device_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Extension
  defdelegate signal_fixture(job, attrs \\ %{}), to: Data.Fixtures.Extension
  defdelegate config_fixture(site, attrs \\ %{}), to: Data.Fixtures.Extension
  defdelegate contact_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Conversations
  defdelegate conversation_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Conversations
  defdelegate message_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Conversations
  defdelegate meeting_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Conversations
  defdelegate approval_fixture(scope, attrs \\ %{}), to: Data.Fixtures.Approvals
  defdelegate policy_fixture(customer, attrs \\ %{}), to: Data.Fixtures.Approvals
  defdelegate notification_fixture(organisation, user, attrs \\ %{}), to: Notices
  defdelegate push_subscription_fixture(user, attrs \\ %{}), to: Notices
  defdelegate preference_fixture(user, group_key, switches \\ %{}), to: Notices
  defdelegate delivery_fixture(notification, attrs \\ %{}), to: Notices

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
