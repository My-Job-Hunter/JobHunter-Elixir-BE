defmodule Mix.Tasks.Aq.World do
  @shortdoc "Rebuilds the cast, tasks, jobs, P4a's leads and the standard set (dev only)"

  @moduledoc """
  The world (AQ-03B §8): an empty database becomes the P3 run's — the
  cast, the customers, P2's nine tasks and P3's thirty jobs, now each in its
  team — made **through the HTTP API as each person**, so every row carries
  the audit, history and notifications the real verbs write.

      AQ_CAST_PASSWORD=… mix aq.world

  It **refuses** unless the database has no user, the server answers at
  `AQ_WORLD_URL` (default `http://localhost:4100`), and `AQ_CAST_PASSWORD`
  is set — the one password every account gets, never written anywhere.

  **Super Admin (`super-admin@example.com`) is the one system admin**
  (AQ-04A §4.0); nobody is a manager. On 2026-11-12 Super Admin replaced
  Dawud (`dawud@example.com`, "Dawud Kalim"): the snapshots name Super
  Admin wherever they named him, so every step he took is Super Admin's
  now, and Dawud is no longer in the cast. Both pipelines are ensured at
  version 1 after the bootstrap (§12).

  The first admin comes from `Core.Organisation.bootstrap/2` in-process, as
  `mix aq.bootstrap` makes them; the invitation is accepted over HTTP, and
  from then on everything is a request: `Api.World.People` (the
  organisation, teams, invitations, customers, profiles, the channel, the
  CV), `Api.World.Board` (stages and tasks), `Api.World.Pool` (companies,
  jobs, the merge, the dismissal, the close and reopen, the archive and
  unarchive, Frontend squad's three). The source is
  `apps/api/priv/world/p3-snapshot.json` and `priv/world/files`
  (`Api.World.Snapshot`). Last (AQ-04B §12), `Api.World.Leads` brings it to
  where P4a's run left it, from `priv/world/p4a-snapshot.json`: Naveed
  active, Tanweer in Frontend squad too, Bamboo's evening job, the Kestrel →
  Plover merge, Employment version 2, the thirteen leads through their
  verbs, the teams' settings and the share link. P5 (AQ-05 §13,
  `Api.World.Extension`): Tanweer's LinkedIn and Upwork (`agency`)
  linked to *Golang backend*, and Naveed's LinkedIn (`customer`, both his
  profiles); the selector documents are the reference seed's v1. P6
  (AQ-06 §13, `Api.World.Conversations`): *Mei Chen* (recruiter, Juniper
  Edge) and *Omar Haddad* (hiring manager, Corvid Security), the contacts
  the run starts from.

  **Last, the standard test set** (`Core.Standard`, the same function
  `mix aq.seed_standard` runs; `docs/TEST-ACCOUNTS.md`): Team 1, 2 and 3 with
  `team-leadN@example.com`, `staffN@example.com` and an active
  `customerN@example.com` each, and 21 jobs from seven boards — made
  in-process through the front door's code, as the people they name, with
  `AQ_CAST_PASSWORD`. So after `mix ecto.reset.clean`, the server and

      AQ_CAST_PASSWORD=password123 mix aq.world

  the world's cast and teams (Backend squad, Frontend squad) and the
  standard set are there side by side. It prints the counts to check
  against the records.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias Api.World.{Board, Conversations, Extension, Http, Leads, People, Pool, Snapshot}
  alias Core.Leads.Pipelines
  alias Data.Repo
  alias Data.Scope

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    if Mix.env() != :dev, do: Mix.raise("mix aq.world runs in dev only")
    Logger.configure(level: :info)

    base = System.get_env("AQ_WORLD_URL", "http://localhost:4100") |> String.trim_trailing("/")
    password = System.get_env("AQ_CAST_PASSWORD")

    refuse_unless(base, password)

    snap = Snapshot.load()
    code = bootstrap(snap)
    pipelines()

    %{
      base: base,
      password: password,
      tokens: %{},
      users: %{},
      admin: nil,
      teams: %{},
      customers: %{},
      profiles: %{},
      skills: %{},
      channels: %{},
      documents: %{},
      tasks: %{},
      comments: %{},
      companies: %{},
      jobs: %{},
      leads: %{}
    }
    |> step("the first admin", &People.admin(&1, snap, code))
    |> step("the organisation", &People.organisation(&1, snap))
    |> step("the teams", &People.teams(&1, snap))
    |> step("the staff", &People.staff(&1, snap))
    |> step("the teams' settings", &People.team_settings(&1, snap))
    |> step("the customers", &People.customers(&1, snap))
    |> step("the skills", &People.skills(&1, snap))
    |> step("the profiles", &People.profiles(&1, snap))
    |> step("the channels", &People.channels(&1, snap))
    |> step("the CV", &People.documents(&1, snap))
    |> step("the stages", &Board.stages(&1, snap))
    |> step("the tasks", &Board.tasks(&1, snap))
    |> step("the companies", &Pool.companies(&1, snap))
    |> step("the jobs", &Pool.jobs(&1, snap))
    |> step("the merge", &Pool.merges(&1, snap))
    |> step("the dismissal", &Pool.dismissals(&1, snap))
    |> step("the close, reopen, archive, unarchive", &Pool.verbs(&1, snap))
    |> step("Frontend squad's jobs", &Pool.frontend(&1, snap))
    |> step(
      "P4a's run: its customers, jobs, Employment v2, leads and share link",
      &Leads.run(&1, snap)
    )
    |> step(
      "P5's channels: Tanweer's LinkedIn and Upwork, Naveed's LinkedIn",
      &Extension.channels(&1, snap)
    )
    |> step("P6's contacts: Mei Chen and Omar Haddad", &Conversations.contacts(&1, snap))
    |> step("the standard set: Team 1–3, their people and 21 jobs", &standard/1)

    counts()
  end

  defp refuse_unless(base, password) do
    if is_nil(password) or password == "",
      do:
        Mix.raise("mix aq.world needs AQ_CAST_PASSWORD (the cast's password; never written down)")

    users = Repo.aggregate(Data.Accounts.User, :count)

    if users > 0,
      do: Mix.raise("mix aq.world needs an empty database: this one has #{users} users")

    unless Http.up?(base), do: Mix.raise("mix aq.world needs the server answering at #{base}")
  end

  defp bootstrap(snap) do
    [org] = snap["organisations"]
    admin = Snapshot.user_by_email(snap, Core.Standard.admin_email())

    params = %{
      org_name: org["name"],
      admin_email: Core.Standard.admin_email(),
      admin_name: Snapshot.name(snap, admin)
    }

    case Data.Seeds.quietly(fn -> Core.Organisation.bootstrap(params, Core.Clock.now()) end) do
      {:ok, %{invitation: invitation}} -> invitation.code
      {:error, reason} -> Mix.raise("Could not bootstrap: #{inspect(reason)}")
    end
  end

  # AQ-04A §12: both pipelines at version 1 (the bootstrap ensures them too;
  # `ensure` is idempotent, so this only says so).
  defp pipelines do
    Mix.shell().info("· the pipelines")
    organisation = Data.Organisations.the_one()
    :ok = Pipelines.ensure(Scope.system(organisation), Core.Clock.now())
  end

  defp step(w, label, fun) do
    Mix.shell().info("· #{label}")
    fun.(w)
  end

  # The standard test set, in-process like the bootstrap: the function
  # `mix aq.seed_standard` runs, with the cast's password. Super Admin is
  # already the system admin, so it keeps the organisation and adds the rest.
  defp standard(w) do
    now = Core.Clock.now()

    case Data.Seeds.quietly(fn -> Core.Standard.ensure(Scope.system(), w.password, now) end) do
      {:ok, %{made: made, kept: kept}} ->
        Mix.shell().info("  made #{length(made)}, kept #{kept}")
        w

      {:error, words} when is_binary(words) ->
        Mix.raise(words)

      {:error, reason} ->
        Mix.raise("Could not ensure the standard set: #{inspect(reason)}")
    end
  end

  defp counts do
    count = fn query -> Repo.aggregate(query, :count) end
    shell = Mix.shell()

    shell.info("\nThe world:")
    shell.info("  accounts     #{count.(Data.Accounts.User)}")
    shell.info("  teams        #{count.(Data.Teams.Team)}")
    shell.info("  customers    #{count.(Data.Customers.Customer)}")
    shell.info("  profiles     #{count.(Data.Customers.Profile)}")
    shell.info("  tasks        #{count.(Data.Tasks.Task)}")

    per_team =
      from(j in Data.Jobs.Job,
        join: t in assoc(j, :team),
        group_by: t.name,
        order_by: t.name,
        select: {t.name, count(j.id)}
      )
      |> Repo.all()

    for {team, n} <- per_team, do: shell.info("  jobs         #{n} in #{team}")
    shell.info("  companies    #{count.(Data.Companies.Company)}")
    shell.info("  merges       #{count.(Data.Jobs.Merge)}")
    shell.info("  dismissals   #{count.(Data.Jobs.Dismissal)}")

    for {key, number} <-
          Repo.all(
            from(v in Data.Pipelines.Version,
              group_by: v.pipeline_key,
              order_by: v.pipeline_key,
              select: {v.pipeline_key, max(v.number)}
            )
          ),
        do: shell.info("  pipeline     #{key} at version #{number}")

    leads =
      from(l in Data.Leads.Lead,
        join: j in assoc(l, :job),
        join: t in assoc(j, :team),
        group_by: t.name,
        order_by: t.name,
        select: {t.name, count(l.id)}
      )
      |> Repo.all()

    for {team, n} <- leads, do: shell.info("  leads        #{n} in #{team}")
    shell.info("  lead events  #{count.(Data.Leads.Event)}")
    shell.info("  share links  #{count.(Data.ShareLinks.ShareLink)}")
    shell.info("  channels     #{count.(Data.Customers.Channel)}")
    shell.info("  contacts     #{count.(Data.Contacts.Contact)}")

    for config <- Data.Extension.configs(),
        do: shell.info("  config       #{config.site} at version #{config.version}")

    admin =
      Repo.one(
        from(a in Data.Organisations.OrgAdmin, join: u in assoc(a, :user), select: u.email)
      )

    shell.info("  admin        #{admin}")
  end
end
