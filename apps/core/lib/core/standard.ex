defmodule Core.Standard do
  @moduledoc """
  The standard test set (the user's words of 2026-11-12;
  `docs/TEST-ACCOUNTS.md` lists it): one organisation, three teams, the ten
  accounts every tester can rely on and 21 jobs, each made **through the
  front door**, so the audit rows are the ones a person would leave.

  | Who | Email | Is |
  |---|---|---|
  | Super Admin | `super-admin@example.com` | the one system admin |
  | Team Lead N | `team-leadN@example.com` | lead of Team N |
  | Staff N | `staffN@example.com` | staff (a member) of Team N |
  | Customer N | `customerN@example.com` | a customer served by Team N: `active`, an accepted portal account, one active profile |

  and three jobs from each of seven boards, one per board in each team's
  pool (`Core.Standard.Pool`).

  **Who makes what**, as the console would: the system bootstraps the
  organisation (`Core.Organisation.bootstrap/2`, `mix aq.bootstrap`'s code)
  and Super Admin accepts its invitation with a name and a password; Super
  Admin makes the teams (`Core.Organisation.Teams`) and invites each team
  lead; each lead invites their staff, makes their team's customer
  (`Core.Customers`), invites them to the portal, makes their profile
  (`Core.Customers.Profiles`) and adds the team's jobs (*New job*'s
  `Core.Jobs.create/3`). Every invitation is accepted through
  `Core.Organisation.Invitations.accept/3`. Each person acts in-process
  with their own scope, resolved as the console's plug resolves it
  (`Core.Access.Grants`), `via: :task` and `request_id: "aq.seed_standard"`.

  **Idempotent.** Each thing is found by its key — the organisation's one
  admin, a team by name, a membership by email, a customer by email, a
  profile by title, a job by its link (`job_exists` from the verb itself)
  — and only what is missing is made: run twice, the second run makes
  nothing. A role, a team, a status or a paused profile that drifted is put
  back through its verb.

  **An organisation that exists already must have Super Admin as its
  system admin** (there is one, QP4a-21); otherwise it stops with words
  saying how to fix it, and makes nothing.

  Callers: `mix aq.seed_standard` (dev only, `password123`, last of
  `mix ecto.reset`'s seeds) and the end of `mix aq.world`. The suite passes
  a strong password: outside a dev server the worst-list refuses
  `password123`.
  """

  alias Core.Access.Grants
  alias Core.Customers
  alias Core.Customers.Profiles
  alias Core.Jobs
  alias Core.Organisation
  alias Core.Organisation.Invitations
  alias Core.Organisation.Teams
  alias Core.Standard.Pool
  alias Data.Accounts
  alias Data.Organisations
  alias Data.Scope

  @organisation "Regbits BD"
  @admin_email "super-admin@example.com"
  @admin_name "Super Admin"
  @request_id "aq.seed_standard"
  @seats [1, 2, 3]

  @profiles %{
    1 => %{
      location: "Lahore",
      title: "Customer 1 · Backend Engineer",
      headline: "Elixir and Go backend engineer: APIs, PostgreSQL, event pipelines",
      years: 6,
      engagements: ["full_time", "contract"],
      workplaces: ["remote"]
    },
    2 => %{
      location: "Karachi",
      title: "Customer 2 · Frontend Engineer",
      headline: "React and Vue engineer who ships design systems",
      years: 5,
      engagements: ["full_time", "freelance_fixed"],
      workplaces: ["remote", "hybrid"]
    },
    3 => %{
      location: "Islamabad",
      title: "Customer 3 · Full-stack Engineer",
      headline: "Phoenix and Vue full-stack engineer for early-stage products",
      years: 7,
      engagements: ["full_time", "contract", "freelance_hourly"],
      workplaces: ["remote"]
    }
  }

  @type summary :: %{made: [String.t()], kept: non_neg_integer()}

  # ── The set, as data ────────────────────────────────────────────────────────

  @doc "The organisation's name, when the standard set has to make it."
  @spec organisation_name() :: String.t()
  def organisation_name, do: @organisation

  @doc "The one system admin's email."
  @spec admin_email() :: String.t()
  def admin_email, do: @admin_email

  @doc "Team `n`'s name."
  @spec team_name(pos_integer()) :: String.t()
  def team_name(n), do: "Team #{n}"

  @doc "The teams' names, in order."
  @spec team_names() :: [String.t()]
  def team_names, do: Enum.map(@seats, &team_name/1)

  @doc "Customer `n`'s one profile title."
  @spec profile_title(pos_integer()) :: String.t()
  def profile_title(n), do: @profiles[n].title

  @doc """
  The ten accounts, in the doc's order: `%{email, name, role, team}`, `role`
  one of `:system_admin`, `:team_lead`, `:staff`, `:customer` and `team` the
  team's name (`nil` for the system admin).
  """
  @spec accounts() :: [map()]
  def accounts do
    [%{email: @admin_email, name: @admin_name, role: :system_admin, team: nil}] ++
      Enum.map(@seats, &lead_account/1) ++
      Enum.map(@seats, &staff_account/1) ++ Enum.map(@seats, &customer_account/1)
  end

  defp lead_account(n),
    do: person(n, "team-lead#{n}@example.com", "Team Lead #{n}", :team_lead, :lead)

  defp staff_account(n),
    do: person(n, "staff#{n}@example.com", "Staff #{n}", :staff, :member)

  defp customer_account(n),
    do: person(n, "customer#{n}@example.com", "Customer #{n}", :customer, nil)

  defp person(n, email, name, role, team_role),
    do: %{email: email, name: name, role: role, team: team_name(n), team_role: team_role}

  # ── Ensure ──────────────────────────────────────────────────────────────────

  @doc """
  Ensures the whole set, as the system (`Data.Scope.system/0`), with
  `password` for every account it makes. Answers `{:ok, %{made, kept}}` —
  what it made, in order, and how many things it found in place — or
  `{:error, words}` when the organisation's system admin is somebody else,
  or `{:error, {team_name | :admin, reason}}` when a verb refused.
  """
  @spec ensure(Scope.t(), String.t(), DateTime.t()) :: {:ok, summary()} | {:error, term()}
  def ensure(%Scope{via: :system} = scope, password, %DateTime{} = now)
      when is_binary(password) do
    run = %{password: password, now: now}

    with {:ok, admin, acc} <- admin(scope, run, %{made: [], kept: 0}),
         {:ok, acc} <- each(@seats, acc, &seat(admin, &1, run, &2)),
         {:ok, acc} <- each(accounts(), acc, &whole_name/2) do
      {:ok, %{made: Enum.reverse(acc.made), kept: acc.kept}}
    end
  end

  # Words call a person by their given name when there is one (`Core.Tasks.Words.first_name/1`),
  # else by the first word of their name: "Team Lead 1" would read "Team", like the hidden
  # staff's "The team", and "Staff 1" "Staff". So each account's whole label is its given name,
  # set through `PATCH /me`'s own verb.
  defp whole_name(%{email: email, name: name}, acc) do
    user = email |> Accounts.get_user_by_email() |> Data.Repo.preload(:person)

    if user.person.given_name == name do
      {:ok, acc}
    else
      with {:ok, _me} <- Core.Accounts.update_me(acting(user), %{"given_name" => name}),
           do: {:ok, made(acc, "the given name #{name}")}
    end
  end

  # ── The organisation and its one admin ──────────────────────────────────────

  defp admin(%Scope{} = scope, run, acc) do
    case Organisations.the_one() do
      nil -> bootstrap(scope, run, acc)
      organisation -> standing(scope, organisation, acc)
    end
  end

  # `mix aq.bootstrap`'s code, then its admin invitation accepted.
  defp bootstrap(%Scope{}, run, acc) do
    params = %{org_name: @organisation, admin_email: @admin_email, admin_name: @admin_name}
    me = %{email: @admin_email, name: @admin_name}

    with {:ok, %{invitation: invitation}} <- Organisation.bootstrap(params, run.now),
         {:ok, user} <- accept(invitation, me, run) do
      made = acc |> made("organisation #{@organisation}") |> made("system admin #{@admin_email}")
      {:ok, acting(user), made}
    else
      {:error, reason} -> {:error, {:admin, reason}}
    end
  end

  defp standing(%Scope{}, organisation, acc) do
    case Organisations.the_admin(organisation.id) do
      %{user: %{email: @admin_email} = user} -> {:ok, acting(user), acc |> kept() |> kept()}
      %{user: user} -> {:error, wrong_admin(organisation, user.email)}
      nil -> {:error, wrong_admin(organisation, nil)}
    end
  end

  defp wrong_admin(organisation, email) do
    who =
      if email,
        do: "#{organisation.name}'s system admin is #{email}, not #{@admin_email}",
        else: "#{organisation.name} has no system admin yet (its bootstrap invitation is open)"

    who <>
      ". The standard set needs #{@admin_email} as the one system admin. Start again with " <>
      "`mix ecto.reset` (the standard set alone) or `mix ecto.reset.clean`, the server and " <>
      "`mix aq.world` (the world and the standard set) — or, keeping this database, hand the " <>
      "role on with `mix aq.admin --to #{@admin_email}` once that account exists."
  end

  # ── One team and its people ─────────────────────────────────────────────────

  defp seat(%Scope{} = admin, n, run, acc) do
    case people(admin, n, run, acc) do
      {:ok, acc} -> {:ok, acc}
      {:error, reason} -> {:error, {team_name(n), reason}}
    end
  end

  defp people(%Scope{} = admin, n, run, acc) do
    with {:ok, team, acc} <- team(admin, team_name(n), acc),
         {:ok, lead_user, acc} <- member(admin, admin, team, lead_account(n), run, acc),
         lead = acting(lead_user),
         {:ok, staff_user, acc} <- member(lead, admin, team, staff_account(n), run, acc),
         seat = %{n: n, team: team, lead: lead, staff: staff_user},
         {:ok, acc} <- serve_customer(admin, seat, run, acc) do
      jobs(lead, seat, run, acc)
    end
  end

  defp team(%Scope{} = admin, name, acc) do
    {:ok, teams} = Teams.list(admin)

    case Enum.find(teams, &(&1.name == name)) do
      %{} = team ->
        {:ok, team, kept(acc)}

      nil ->
        with {:ok, team} <- Teams.create(admin, %{"name" => name}),
             do: {:ok, team, made(acc, "team #{name}")}
    end
  end

  # Somebody in `team` with their role: kept when they are; the role put
  # back by the system admin when it drifted; else invited by `inviter`
  # (the system admin for a lead, the lead for staff) and accepted.
  defp member(%Scope{} = inviter, %Scope{} = admin, team, person, run, acc) do
    {:ok, members} = Teams.list_members(admin, team.id)

    case Enum.find(members, &(&1.user.email == person.email)) do
      nil ->
        join(inviter, team, person, run, acc)

      %{role: role, user: user} when role == person.team_role ->
        {:ok, user, kept(acc)}

      %{user: user} ->
        with {:ok, _member} <- Teams.change_role(admin, team.id, user.id, person.team_role),
             do: {:ok, user, made(acc, "#{person.email} back to #{person.team_role}")}
    end
  end

  defp join(%Scope{} = inviter, team, person, run, acc) do
    params = %{
      "kind" => "team_member",
      "email" => person.email,
      "invited_name" => person.name,
      "team_id" => team.id,
      "role" => to_string(person.team_role)
    }

    with {:ok, invitation, _status} <- Invitations.issue(inviter, params, run.now),
         {:ok, user} <- accept(invitation, person, run) do
      {:ok, user, made(acc, "#{word(person.role)} #{person.email} in #{team.name}")}
    end
  end

  # ── The team's customer ─────────────────────────────────────────────────────

  defp serve_customer(%Scope{} = admin, seat, run, acc) do
    person = customer_account(seat.n)

    with {:ok, customer, acc} <- customer_row(admin, seat, person, run, acc),
         {:ok, customer, acc} <- served(admin, customer, seat.team, run, acc),
         {:ok, customer, acc} <- portal(admin, seat.lead, customer, person, run, acc),
         {:ok, customer, acc} <- active(seat.lead, customer, run, acc) do
      profile(admin, seat, customer, run, acc)
    end
  end

  defp customer_row(%Scope{} = admin, seat, person, run, acc) do
    {:ok, found} = Customers.list(admin, %{"q" => person.email})

    case Enum.find(found, &(&1.email == person.email)) do
      %{} = customer ->
        {:ok, customer, kept(acc)}

      nil ->
        params = %{
          "display_name" => person.name,
          "email" => person.email,
          "team_ids" => [seat.team.id],
          "country_code" => "PK",
          "location_text" => @profiles[seat.n].location
        }

        with {:ok, customer} <- Customers.create(seat.lead, params, run.now),
             do: {:ok, customer, made(acc, "customer #{person.email} in #{seat.team.name}")}
    end
  end

  defp served(%Scope{} = admin, customer, team, run, acc) do
    if team.id in customer.team_ids do
      {:ok, customer, acc}
    else
      with {:ok, customer} <- Customers.assign_team(admin, customer.id, team.id, run.now),
           do: {:ok, customer, made(acc, "#{customer.email} served by #{team.name}")}
    end
  end

  # The portal invitation, by the lead, accepted with a name and a password:
  # the login attached, `invited` becoming `active` (`Core.Customers.attach_login/4`).
  defp portal(%Scope{} = admin, %Scope{} = lead, %{user_id: nil} = customer, person, run, acc) do
    with {:ok, invitation, _status} <- Customers.invite(lead, customer.id, run.now),
         {:ok, _user} <- accept(invitation, person, run),
         {:ok, customer} <- Customers.get(admin, customer.id) do
      {:ok, customer, made(acc, "portal account #{person.email}")}
    end
  end

  defp portal(%Scope{}, %Scope{}, customer, _person, _run, acc), do: {:ok, customer, kept(acc)}

  defp active(%Scope{}, %{status: :active} = customer, _run, acc), do: {:ok, customer, acc}

  defp active(%Scope{} = lead, customer, run, acc) do
    with {:ok, customer} <- Customers.change_status(lead, customer.id, "active", run.now),
         do: {:ok, customer, made(acc, "#{customer.email} active")}
  end

  # One active profile, owned by the team's staff member, so leads can be made for it.
  defp profile(%Scope{} = admin, seat, customer, run, acc) do
    wanted = @profiles[seat.n]
    {:ok, profiles} = Profiles.list(admin, customer.id)

    case Enum.find(profiles, &(&1.title == wanted.title)) do
      nil ->
        with {:ok, _profile} <-
               Profiles.create(seat.lead, customer.id, profile_params(wanted, seat), run.now),
             do: {:ok, made(acc, "profile #{wanted.title}")}

      %{status: :active} ->
        {:ok, kept(acc)}

      profile ->
        with {:ok, _profile} <-
               Profiles.update_facts(seat.lead, profile.id, %{"status" => "active"}),
             do: {:ok, made(acc, "profile #{wanted.title} active")}
    end
  end

  defp profile_params(wanted, seat) do
    %{
      "title" => wanted.title,
      "headline" => wanted.headline,
      "seniority" => "mid_senior",
      "years_experience" => wanted.years,
      "engagement_types" => wanted.engagements,
      "workplace_types" => wanted.workplaces,
      "owner_ids" => [seat.staff.id]
    }
  end

  # ── The team's jobs ─────────────────────────────────────────────────────────

  # *New job*'s verb, by the lead; a link already in the team's pool is the
  # verb's own `job_exists`, and kept.
  defp jobs(%Scope{} = lead, seat, run, acc) do
    each(Pool.for_team(seat.n), acc, fn job, acc ->
      case Jobs.create(lead, Pool.params(job, seat.team.id, run.now), run.now) do
        {:ok, _sheet} -> {:ok, made(acc, "#{job.source} job #{job.title} in #{seat.team.name}")}
        {:error, {:job_exists, _job}} -> {:ok, kept(acc)}
        {:error, _reason} = error -> error
      end
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # An invitation accepted as the front door accepts it: a new account with
  # the name and the password, or — for an address that has an account —
  # signed in as it.
  defp accept(invitation, person, run) do
    params = %{"name" => person.name, "password" => run.password}
    current = Accounts.get_user_by_email(person.email)

    case Invitations.accept(invitation.code, params, now: run.now, current_user: current) do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _reason} = error -> error
    end
  end

  # The person's own scope, as the console's plug resolves it.
  defp acting(user), do: Grants.scope_for(user, via: :task, request_id: @request_id)

  defp each(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp made(acc, what), do: %{acc | made: [what | acc.made]}
  defp kept(acc), do: %{acc | kept: acc.kept + 1}

  defp word(:team_lead), do: "team lead"
  defp word(:staff), do: "staff"
end
