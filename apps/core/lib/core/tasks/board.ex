defmodule Core.Tasks.Board do
  @moduledoc """
  The console's board page (AQ-02 §7.2, §7.6; AQ-03B §5.1): **one team's
  board** (`team_id`, required) over the tasks the caller sees there
  (`Core.Tasks.Visibility`), the six columns in vocabulary order, Done and
  Closed showing 30 days with the older counted (`older_done`,
  `older_closed`), In progress grouped **by stage with `mine=true`, else by
  primary assignee** (QP2-10), and order within a column by the chosen sort
  (QP2-9: a drop changes the state only).

  P2's views are filters of the team's board now; `view` is gone (422):

  | Filter | Keeps |
  |---|---|
  | `mine=true` | assigned to me, my open steps on other tasks (as step cards), my own unassigned tasks and drafts (QP2-16) |
  | `watching=true` | the tasks I watch |
  | `customer_id` | the customer's tasks (a customer the caller may read) |

  A member whose team's `peer_tasks` is `hidden` sees their own; with none,
  `empty: "team_hidden"`. And P2's filters: `q`, `priority` (comma-separated, `normal`
  for none), `due ∈ today · overdue · week · none`, `people`, `profile_id`,
  `stage_id`, `no_owner`, `archived`, `older ∈ done · closed`; `sort ∈ due ·
  priority · newest`.
  """

  alias Core.Access
  alias Core.Tasks.{Cards, Person, Visibility}
  alias Data.Customers
  alias Data.Scope
  alias Data.Tasks, as: Store
  alias Data.TaskStages
  alias Data.Teams

  @states Data.Tasks.Task.states()
  @older_days 30
  @rank %{urgent: 0, high: 1, nil: 2, low: 3}

  @doc "`GET /board?team_id&…`: the page."
  @spec page(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with true <- Scope.staff?(scope) || {:error, :not_found},
         :ok <- no_view(params),
         {:ok, team} <- team(scope, params["team_id"]),
         {:ok, view, spec} <- view(scope, team, params) do
      me = Scope.user_id(scope)
      tasks = Store.list(Visibility.filter(scope), view: spec, archived: on?(params["archived"]))
      ctx = Cards.context(scope, tasks, now)
      entries = entries(ctx, tasks, view, me)

      hidden? =
        Scope.team_role(scope, team.id) == :member and not Visibility.peers?(scope, team.id)

      people = people(entries)
      shown = entries |> filter(params, ctx) |> sort(params["sort"])
      {columns, older} = columns(shown, params["older"], now)
      stages = TaskStages.list(me)

      {:ok,
       %{
         counts: %{
           due_today:
             Enum.count(shown, fn {task, _item} -> open?(task) and due_today?(task, ctx) end),
           overdue: Enum.count(shown, fn {task, _item} -> Cards.overdue?(task, ctx) end),
           by_state: Map.new(columns, fn {state, items} -> {state, length(items)} end),
           older_done: older.done,
           older_closed: older.closed
         },
         columns:
           Enum.map(
             @states,
             &%{state: &1, items: Enum.map(columns[&1], fn {_t, item} -> item end)}
           ),
         in_progress_groups: groups(view, columns[:in_progress], stages),
         stages: Enum.map(stages, &%{id: &1.id, name: &1.name, position: &1.position}),
         people: people,
         team: %{id: team.id, name: team.name},
         teams: teams(scope),
         empty: empty(view, hidden?, entries)
       }}
    end
  end

  # ── The team and the filters ────────────────────────────────────────────────

  # AQ-03B §5.1: the views became filters; `view` is refused rather than ignored.
  defp no_view(%{"view" => _any}),
    do: {:error, {:invalid, %{"view" => ["is gone: use mine, watching or customer_id"]}}}

  defp no_view(_params), do: :ok

  # The team: required; a live team the caller is in, or any for an admin.
  defp team(scope, team_id) do
    case Utils.presence(to_string(team_id || "")) do
      nil ->
        {:error, {:invalid, %{"team_id" => ["is required"]}}}

      id ->
        with %{archived_at: nil} = team <- Teams.get(Scope.organisation_id(scope), id),
             true <- Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team.id)) do
          {:ok, team}
        else
          _other -> {:error, :not_found}
        end
    end
  end

  # `:mine` when `mine=true` (step cards, grouped by stage), else `:team`;
  # the narrowings `Data.Tasks.list/2` applies, the team's first.
  defp view(scope, team, params) do
    me = Scope.user_id(scope)
    mine = if on?(params["mine"]), do: [{:mine, me}], else: []
    watching = if on?(params["watching"]), do: [{:watching, me}], else: []

    with {:ok, customer} <- customer(scope, params["customer_id"]) do
      view =
        cond do
          mine != [] -> :mine
          customer != [] -> :customer
          true -> :team
        end

      {:ok, view, [{:team, team.id}] ++ mine ++ watching ++ customer}
    end
  end

  defp customer(scope, id) do
    case Utils.presence(to_string(id || "")) do
      nil ->
        {:ok, []}

      id ->
        with %{} = customer <-
               Customers.get(Scope.organisation_id(scope), id) || {:error, :not_found},
             :ok <- Access.why_not(scope, :read, {:customer, customer}),
             do: {:ok, [{:customer, customer.id}]}
    end
  end

  # Mine keeps what is mine as cards and my open steps on the rest as step
  # cards; otherwise every task is its card.
  defp entries(ctx, tasks, :mine, me), do: Enum.flat_map(tasks, &mine(ctx, &1, me))
  defp entries(ctx, tasks, _view, _me), do: Enum.map(tasks, &{&1, Cards.card(ctx, &1)})

  defp mine(ctx, task, me) do
    if Cards.mine?(task, me) or (task.state == :draft and task.author_user_id == me),
      do: [{task, Cards.card(ctx, task)}],
      else:
        for(
          step <- task.steps,
          step.assignee_user_id == me and is_nil(step.done_at),
          do: {task, Cards.step_card(ctx, task, step)}
        )
  end

  # ── Filters and order ───────────────────────────────────────────────────────

  defp filter(entries, params, ctx) do
    tests = [
      q: &text?(&1, params["q"]),
      priority: &priority?(&1, csv(params["priority"])),
      due: &due?(&1, params["due"], ctx),
      people: &people?(&1, csv(params["people"])),
      profile_id: &(&1.profile_id == params["profile_id"]),
      stage_id: &(&1.stage_id == params["stage_id"]),
      no_owner: &(not Enum.any?(&1.participants, fn p -> p.level end))
    ]

    active =
      for {key, test} <- tests,
          (key == :no_owner and on?(params["no_owner"])) or
            (key != :no_owner and present?(params[to_string(key)])),
          do: test

    Enum.filter(entries, fn {task, _item} -> Enum.all?(active, & &1.(task)) end)
  end

  defp text?(task, q),
    do: String.contains?(String.downcase(task.title), String.downcase(String.trim(q)))

  defp priority?(task, wanted),
    do: Enum.any?(wanted, &(&1 == to_string(task.priority || "normal")))

  defp people?(task, ids), do: Enum.any?(task.participants, &(&1.level && &1.user_id in ids))

  defp due?(task, "today", ctx), do: due_today?(task, ctx)
  defp due?(task, "overdue", ctx), do: Cards.overdue?(task, ctx)
  defp due?(task, "none", _ctx), do: is_nil(task.due_at) and is_nil(task.due_on)

  defp due?(task, "week", ctx) do
    case due_day(task, ctx) do
      nil -> false
      day -> Date.diff(day, ctx.today) in 0..6
    end
  end

  defp due?(_task, _other, _ctx), do: true

  defp due_today?(task, ctx), do: due_day(task, ctx) == ctx.today

  defp due_day(%{due_on: %Date{} = on}, _ctx), do: on

  defp due_day(%{due_at: %DateTime{} = at}, ctx) do
    case DateTime.shift_zone(at, ctx.zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(at)
    end
  end

  defp due_day(_task, _ctx), do: nil

  defp sort(entries, "newest"),
    do: Enum.sort_by(entries, fn {t, _i} -> t.inserted_at end, {:desc, DateTime})

  defp sort(entries, "priority"),
    do: Enum.sort_by(entries, fn {t, _i} -> {Map.fetch!(@rank, t.priority), due_key(t)} end)

  defp sort(entries, _due), do: Enum.sort_by(entries, fn {t, _i} -> due_key(t) end)

  # Due first, soonest first (a day sorts at its end); no due last; then the oldest.
  defp due_key(%{due_at: %DateTime{} = at} = t),
    do: {0, DateTime.to_unix(at, :microsecond), created(t)}

  defp due_key(%{due_on: %Date{} = on} = t),
    do: {0, DateTime.to_unix(DateTime.new!(on, ~T[23:59:59.999999]), :microsecond), created(t)}

  defp due_key(t), do: {1, 0, created(t)}

  defp created(t), do: DateTime.to_unix(t.inserted_at, :microsecond)

  # Done and Closed show 30 days unless `older` opens them.
  defp columns(entries, older, now) do
    cutoff = DateTime.add(now, -@older_days, :day)
    by_state = Enum.group_by(entries, fn {t, _i} -> t.state end)

    older? = fn {t, _i} ->
      at = t.done_at || t.closed_at
      at && DateTime.compare(at, cutoff) == :lt
    end

    {done_old, done} = Enum.split_with(Map.get(by_state, :done, []), older?)
    {closed_old, closed} = Enum.split_with(Map.get(by_state, :closed, []), older?)

    columns =
      @states
      |> Map.new(&{&1, Map.get(by_state, &1, [])})
      |> Map.put(:done, if(older == "done", do: done ++ done_old, else: done))
      |> Map.put(:closed, if(older == "closed", do: closed ++ closed_old, else: closed))

    {columns, %{done: length(done_old), closed: length(closed_old)}}
  end

  # ── Groups, people, teams ───────────────────────────────────────────────────

  defp groups(:mine, entries, stages) do
    by_stage = Enum.group_by(entries, fn {t, _i} -> t.stage_id end)
    mine = MapSet.new(stages, & &1.id)

    staged =
      for s <- stages, items = Map.get(by_stage, s.id, []), items != [] do
        %{
          key: s.id,
          label: s.name,
          stage: %{id: s.id, name: s.name},
          person: nil,
          items: items(items)
        }
      end

    rest = Enum.reject(entries, fn {t, _i} -> t.stage_id && MapSet.member?(mine, t.stage_id) end)
    staged ++ last("none", "No stage", rest)
  end

  defp groups(_view, entries, _stages) do
    by_primary = Enum.group_by(entries, fn {t, _i} -> primary(t) end)

    named =
      by_primary
      |> Enum.reject(fn {user, _items} -> is_nil(user) end)
      |> Enum.sort_by(fn {user, _items} -> user.person.display_name end)
      |> Enum.map(fn {user, items} ->
        %{
          key: user.id,
          label: user.person.display_name,
          stage: nil,
          person: Person.view(user),
          items: items(items)
        }
      end)

    named ++ last("nobody", "Nobody yet", Map.get(by_primary, nil, []))
  end

  defp last(_key, _label, []), do: []

  defp last(key, label, entries),
    do: [%{key: key, label: label, stage: nil, person: nil, items: items(entries)}]

  defp items(entries), do: Enum.map(entries, fn {_t, item} -> item end)

  defp primary(task), do: Enum.find_value(task.participants, &(&1.level == :primary && &1.user))

  defp people(entries) do
    entries
    |> Enum.flat_map(fn {t, _i} -> for p <- t.participants, p.level, do: p.user end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.person.display_name)
    |> Enum.map(&Person.view/1)
  end

  # The caller's teams, with their role in each; an admin sees every team.
  defp teams(scope) do
    ids = if Scope.admin?(scope), do: nil, else: Scope.team_ids(scope)

    scope
    |> Scope.organisation_id()
    |> Teams.list(if(ids, do: [ids: ids], else: []))
    |> Enum.map(&%{id: &1.id, name: &1.name, role: Scope.team_role(scope, &1.id) || :admin})
  end

  defp empty(_view, true, []), do: "team_hidden"
  defp empty(view, _hidden, []), do: Atom.to_string(view)
  defp empty(_view, _hidden, _entries), do: nil

  defp open?(task), do: task.state in [:todo, :in_progress, :on_hold]

  defp csv(nil), do: []

  defp csv(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp csv(values) when is_list(values), do: values

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp on?(value), do: value in [true, "true", "1"]
end
