defmodule Core.Tasks.Portal do
  @moduledoc """
  The customer's side of the board (AQ-02 §7.3, QP2-4, §9), on a scope
  pinned to the customer: their board — **Waiting on you · With the team ·
  Done** — the tasks they add, and their edits. The verbs (*Mark done*,
  *Reopen*, *Withdraw*) are `Core.Tasks.Act.portal/5`; the sheet, the
  thread, the files and the ticks are the same functions the console
  calls, decided by `Core.Access`.

  **A task from the customer** (§9, QP2-3, AQ-03B §5.1): on the team of the
  profile's first owner that serves the customer (by name, when several),
  else the first team serving the customer by name — every task is in a
  team, so a customer no team serves is refused; the profile's owners all assigned, the earliest (`since_on`, then
  the oldest row) primary; `source` customer, shared, To do. The owners are
  told (`tasks.customer_created`); with no owner the team's leads (the system admin when it has none).
  """

  alias Core.Tasks
  alias Core.Tasks.{Cards, Notices, Visibility, Write}
  alias Data.Customers
  alias Data.Organisations
  alias Data.Profiles
  alias Data.Scope
  alias Data.Tasks, as: Store
  alias Data.Teams

  @open [:todo, :in_progress, :on_hold]
  @older_days 30
  @no_team_words "No team serves you yet, so a task has nowhere to go. Ask the agency to add one."

  @doc "`GET /client/v1/board`: `{waiting_on_you, with_team, done, older_done, empty}`."
  @spec board(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def board(%Scope{} = scope, %DateTime{} = now) do
    with :ok <- customer(scope) do
      tasks = Store.list(Visibility.filter(scope))
      ctx = Cards.context(scope, tasks, now)
      cutoff = DateTime.add(now, -@older_days, :day)
      {open, finished} = Enum.split_with(tasks, &(&1.state in @open))
      {waiting, with_team} = Enum.split_with(open, &Cards.yours_to_do?/1)

      {recent, older} =
        Enum.split_with(finished, &(DateTime.compare(&1.done_at || &1.closed_at, cutoff) != :lt))

      card = &Cards.portal_card(ctx, &1)

      board = %{
        waiting_on_you: waiting |> by_due() |> Enum.map(card),
        with_team: with_team |> by_due() |> Enum.map(card),
        done:
          recent
          |> Enum.sort_by(&(&1.done_at || &1.closed_at), {:desc, DateTime})
          |> Enum.map(card),
        older_done: length(older)
      }

      {:ok, Map.put(board, :empty, tasks == [])}
    end
  end

  defp by_due(tasks) do
    Enum.sort_by(tasks, fn t ->
      cond do
        t.due_at -> {0, DateTime.to_unix(t.due_at)}
        t.due_on -> {0, DateTime.to_unix(DateTime.new!(t.due_on, ~T[23:59:59]))}
        true -> {1, DateTime.to_unix(t.inserted_at)}
      end
    end)
  end

  @doc "`POST /client/v1/tasks {title, description?, profile_id?, due_on?}`: routed by §9. Answers the portal sheet."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = Tasks.stringify(params)
    org_id = Scope.organisation_id(scope)

    with :ok <- customer(scope),
         %{} = customer <- Customers.get(org_id, Scope.customer_id(scope)) || {:error, :not_found},
         {:ok, profile} <- profile(customer, Tasks.blank(params["profile_id"])),
         owners = owners(profile),
         {:ok, team_id} <- team(customer, owners) do
      told = if owners == [], do: triage(org_id, team_id), else: owners

      attrs = %{
        "organisation_id" => org_id,
        "author_user_id" => Scope.user_id(scope),
        "source" => "customer",
        "state" => "todo",
        "customer_access" => "shared",
        "customer_id" => customer.id,
        "team_id" => team_id,
        "profile_id" => profile && profile.id,
        "title" => params["title"],
        "description" => params["description"],
        "due_on" => params["due_on"]
      }

      assignees = {List.first(owners), Enum.drop(owners, 1)}
      notify = fn task -> Notices.customer_created(scope, task, told) end

      result =
        Write.commit(fn -> Tasks.insert(scope, attrs, assignees, [], [], now, told: notify) end)

      Tasks.answer(scope, result, now)
    end
  end

  @doc "`PATCH /client/v1/tasks/:id {title?, description?}`: their own task, while it is To do."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    attrs = params |> Tasks.stringify() |> Map.take(~w(title description))

    with {:ok, task} <- Tasks.fetch(scope, :edit_own, id) do
      Tasks.answer(scope, Write.commit(fn -> Tasks.save(scope, task, attrs, now) end), now)
    end
  end

  # ── §9 ──────────────────────────────────────────────────────────────────────

  defp profile(_customer, nil), do: {:ok, nil}

  defp profile(customer, id) do
    case Profiles.get(id) do
      %{customer_id: cid, archived_at: nil} = profile when cid == customer.id -> {:ok, profile}
      _other -> {:error, :not_found}
    end
  end

  # The profile's owners, the earliest first: `since_on`, then the oldest row
  # (ids are UUIDv7, so creation order).
  defp owners(nil), do: []

  defp owners(profile) do
    profile.profile_members
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.since_on), &1.id})
    |> Enum.map(& &1.user_id)
  end

  # The customer's live teams by name; the first the profile's first owner
  # is in, else the first. A customer no team serves cannot add a task.
  defp team(customer, owners) do
    teams =
      customer.customer_teams
      |> Enum.filter(&is_nil(&1.team.archived_at))
      |> Enum.sort_by(&{&1.team.name, &1.team_id})
      |> Enum.map(& &1.team_id)

    members = teams |> Teams.memberships_in() |> Enum.group_by(& &1.team_id, & &1.user_id)
    first_owner = List.first(owners)

    case Enum.find(teams, &(first_owner in Map.get(members, &1, []))) || List.first(teams) do
      nil -> {:error, {:forbidden, @no_team_words}}
      team_id -> {:ok, team_id}
    end
  end

  # Nobody owns it: the team's leads; with none, the system admin.
  defp triage(org_id, nil), do: org_id |> Organisations.list_admins() |> Enum.map(& &1.user_id)

  defp triage(org_id, team_id) do
    members = Teams.list_members(team_id)

    case for(m <- members, m.role == :lead, do: m.user_id) do
      [_ | _] = leads -> leads
      [] -> triage(org_id, nil)
    end
  end

  defp customer(scope), do: if(Scope.customer?(scope), do: :ok, else: {:error, :not_found})
end
