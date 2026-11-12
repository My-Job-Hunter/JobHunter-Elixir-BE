defmodule Core.Leads.Board do
  @moduledoc """
  `GET /leads/board?team_id&view&pipeline&customer&profile&owner&source&
  engagement&workplace&stage&q&quiet&archived` (AQ-04A §8.1, §8.3): **one
  team's leads** as columns.

  - **Collapsed** (the default): To do · In progress · On hold · Done; In
    progress sorted by stage position, then by activity.
  - **Expanded**, one pipeline at a time (`pipeline` required): To do, one
    column per stage of the live version, then any **retired** stage that
    still holds leads (`stage.retired: true`, QP4a-3), On hold, Done. A
    lead on an older version sits in the column of its stage's key.
  - **Done** shows 30 days (by `finished_at`); `older_done` counts the rest.
  - `empty`: `"team_hidden"` for a member at `peer_leads: hidden` with
    nothing of their own; `"mine"` for `owner=me` with nothing; `"team"`
    for a team with no lead at all; else `null` (nothing matches the
    filters).

  `team_id` is required (P3b's 422 and 404). A member at `hidden` sees only
  their own leads. Every other parameter is optional; a value off its list
  is a field error, never a silent "all".
  """

  alias Core.Access
  alias Core.Access.Leads, as: LeadAccess
  alias Core.Jobs
  alias Core.Leads.{Labels, Pipelines, Sheet, Signals}
  alias Core.Tasks.Person
  alias Data.Companies.Company
  alias Data.Leads, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @done_days 30
  @lists [
    {"source", :sources, Vocabulary.job_sources()},
    {"engagement", :engagements, Vocabulary.engagement_types()},
    {"workplace", :workplaces, Vocabulary.workplace_types()}
  ]

  @doc "The board: `{team, view, pipeline, columns, older_done, empty}`."
  @spec show(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def show(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, view} <- view(params["view"]),
         {:ok, pipeline} <- pipeline(scope, view, params["pipeline"]),
         {:ok, lane} <- lane(params["lane"]),
         {:ok, filters} <- filters(scope, team, params, now) do
      reach = LeadAccess.board_reach(scope, team.id)
      visible = if match?({:own, _}, reach), do: elem(reach, 1), else: :all
      filters = Map.put(filters, :visible_to, visible)

      filters =
        if pipeline, do: Map.put(filters, :pipeline_key, pipeline.pipeline_key), else: filters

      leads = Store.for_team(team.id, filters)
      today = Sheet.today(scope, now)
      ctx = Signals.context(scope.organisation, leads, now)
      older? = params["older"] in [true, "true"]
      cards = %{today: today, ctx: ctx, now: now, older?: older?}
      {columns, older} = columns(view, pipeline, leads, cards)

      {:ok,
       %{
         team: %{id: team.id, name: team.name},
         view: view,
         pipeline: pipeline && Pipelines.view(scope, pipeline),
         columns: columns,
         older_done: older,
         empty: empty(leads, reach, params, team.id, filters),
         lane: lane,
         lanes: lanes(lane, view, pipeline, leads, cards)
       }}
    end
  end

  defp view(nil), do: {:ok, :collapsed}
  defp view("collapsed"), do: {:ok, :collapsed}
  defp view("expanded"), do: {:ok, :expanded}
  defp view(_other), do: invalid("view", "is collapsed or expanded")

  defp pipeline(_scope, :collapsed, _key), do: {:ok, nil}

  defp pipeline(_scope, :expanded, nil),
    do: invalid("pipeline", "is required with the expanded view")

  defp pipeline(scope, :expanded, key) do
    case Enum.find(Pipelines.keys(), &(to_string(&1) == to_string(key))) do
      nil -> invalid("pipeline", "is employment or freelance")
      key -> {:ok, Pipelines.live(scope, key)}
    end
  end

  # ── Columns ─────────────────────────────────────────────────────────────────

  defp columns(:collapsed, nil, leads, cards) do
    by_state = Enum.group_by(leads, & &1.state)
    {done, older} = done(Map.get(by_state, :done, []), cards)

    in_progress =
      by_state
      |> Map.get(:in_progress, [])
      |> Enum.sort_by(&{position(&1), -DateTime.to_unix(&1.last_activity_at, :microsecond)})

    {[
       column("todo", :todo, nil, Map.get(by_state, :todo, []), cards),
       column("in_progress", :in_progress, nil, in_progress, cards),
       column("on_hold", :on_hold, nil, Map.get(by_state, :on_hold, []), cards),
       column("done", :done, nil, done, cards)
     ], older}
  end

  defp columns(:expanded, version, leads, cards) do
    by_state = Enum.group_by(leads, & &1.state)
    in_progress = Map.get(by_state, :in_progress, [])
    by_key = Enum.group_by(in_progress, & &1.stage.key)
    live_keys = Enum.map(version.stages, & &1.key)

    stages =
      for stage <- version.stages do
        column(
          stage.key,
          :in_progress,
          Pipelines.stage(stage),
          Map.get(by_key, stage.key, []),
          cards
        )
      end

    retired =
      for {key, [first | _] = held} <- by_key, key not in live_keys do
        stage = first.stage |> Pipelines.stage() |> Map.put(:retired, true)
        column(key, :in_progress, stage, held, cards)
      end
      |> Enum.sort_by(& &1.stage.position)

    {done, older} = done(Map.get(by_state, :done, []), cards)

    {[column("todo", :todo, nil, Map.get(by_state, :todo, []), cards)] ++
       stages ++
       retired ++
       [
         column("on_hold", :on_hold, nil, Map.get(by_state, :on_hold, []), cards),
         column("done", :done, nil, done, cards)
       ], older}
  end

  defp column(key, state, stage, leads, cards) do
    %{
      key: key,
      state: state,
      stage: stage,
      cards: Enum.map(leads, &card(&1, cards)),
      count: length(leads)
    }
  end

  defp card(lead, %{today: today, ctx: ctx}),
    do: Sheet.card(lead, today, Signals.for_lead(ctx, lead))

  # Done shows 30 days; the rest is counted behind "Older · N" — and with
  # `older=true` (AQ-04B §8.1) Done shows every one of them, newest first.
  defp done(leads, %{older?: true}),
    do: {Enum.sort_by(leads, & &1.finished_at, {:desc, DateTime}), 0}

  defp done(leads, %{now: now}) do
    since = DateTime.add(now, -@done_days * 86_400, :second)
    {recent, older} = Enum.split_with(leads, &(DateTime.compare(&1.finished_at, since) != :lt))
    {Enum.sort_by(recent, & &1.finished_at, {:desc, DateTime}), length(older)}
  end

  defp position(%{stage: %{position: position}}), do: position
  defp position(_lead), do: 0

  defp empty([], {:own, me}, _params, team_id, _filters) do
    if Store.for_team(team_id, %{visible_to: me}) == [], do: "team_hidden", else: nil
  end

  defp empty([], _reach, params, team_id, filters) do
    cond do
      params["owner"] == "me" -> "mine"
      Store.for_team(team_id, %{archived: filters.archived}) == [] -> "team"
      true -> nil
    end
  end

  defp empty(_leads, _reach, _params, _team_id, _filters), do: nil

  # ── Parameters ──────────────────────────────────────────────────────────────

  @doc false
  # The board's filters (§8.1), shared with the Tracker: `team` for the
  # labels, which must be the team's.
  def filters(scope, team, params, now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    base = %{
      archived: params["archived"] in [true, "true"],
      q: Company.normalize(Utils.presence(to_string(params["q"] || ""))),
      stage_key: Utils.presence(to_string(params["stage"] || ""))
    }

    steps = [
      &lists(&1, params),
      &uuid(&1, :customer_id, "customer", params["customer"]),
      &uuid(&1, :profile_id, "profile", params["profile"]),
      &owner(&1, scope, params["owner"]),
      &quiet(&1, params["quiet"], now),
      &states(&1, params["state"]),
      &labels(&1, team, params["label"])
    ]

    Enum.reduce_while(steps, {:ok, base}, fn step, {:ok, acc} ->
      case step.(acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp lists(acc, params) do
    Enum.reduce_while(@lists, {:ok, acc}, fn {param, key, allowed}, {:ok, acc} ->
      values = split(params[param])

      if Enum.all?(values, &(&1 in allowed)),
        do: {:cont, {:ok, Map.put(acc, key, Enum.map(values, &String.to_existing_atom/1))}},
        else: {:halt, invalid(param, "has a value that is not one of the list")}
    end)
  end

  defp uuid(acc, _key, _param, nil), do: {:ok, acc}
  defp uuid(acc, _key, _param, ""), do: {:ok, acc}

  defp uuid(acc, key, param, value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, Map.put(acc, key, id)}
      :error -> invalid(param, "is not an id")
    end
  end

  defp owner(acc, scope, "me"), do: {:ok, Map.put(acc, :owner_user_id, Scope.user_id(scope))}
  defp owner(acc, _scope, value), do: uuid(acc, :owner_user_id, "owner", value)

  defp quiet(acc, nil, _now), do: {:ok, acc}
  defp quiet(acc, "", _now), do: {:ok, acc}

  defp quiet(acc, days, now) when days in ["30", "60", 30, 60] do
    days = if is_binary(days), do: String.to_integer(days), else: days
    {:ok, Map.put(acc, :quiet_before, DateTime.add(now, -days * 86_400, :second))}
  end

  defp quiet(_acc, _days, _now), do: invalid("quiet", "is 30 or 60 days")

  # AQ-04B: the Tracker's and the board's state and label filters.
  defp states(acc, value) do
    values = split(value)

    if Enum.all?(values, &(&1 in Vocabulary.lead_states())),
      do: {:ok, Map.put(acc, :states, Enum.map(values, &String.to_existing_atom/1))},
      else: invalid("state", "has a value that is not a state")
  end

  defp labels(acc, team, value) do
    case split(value) do
      [] ->
        {:ok, acc}

      ids ->
        with {:ok, labels} <- Labels.of_team(team.id, ids),
             do: {:ok, Map.put(acc, :label_ids, Enum.map(labels, & &1.id))}
    end
    |> case do
      {:error, {:invalid, _}} -> invalid("label", "has a label that is not this team's")
      other -> other
    end
  end

  # ── Lanes (AQ-04B §9, QP4b-20) ──────────────────────────────────────────────

  defp lane(nil), do: {:ok, :none}
  defp lane(""), do: {:ok, :none}

  defp lane(value) do
    if to_string(value) in Vocabulary.board_lanes(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: invalid("lane", "is none, customer, profile, owner or source")
  end

  # Each lane is a row of the same columns with its own counts, by name.
  defp lanes(:none, _view, _pipeline, _leads, _cards), do: nil

  defp lanes(lane, view, pipeline, leads, cards) do
    leads
    |> Enum.group_by(&lane_of(lane, &1))
    |> Enum.map(fn {{key, name}, held} ->
      {columns, _older} = columns(view, pipeline, held, cards)
      %{key: key, name: name, count: length(held), columns: columns}
    end)
    |> Enum.sort_by(&{String.downcase(to_string(&1.name)), &1.key})
  end

  @doc false
  # A lead's lane (or the Tracker's group) as `{key, name}`.
  def lane_of(:customer, lead),
    do: {lead.profile.customer_id, lead.profile.customer.display_name}

  def lane_of(:profile, lead),
    do: {lead.profile_id, "#{lead.profile.customer.display_name} · #{lead.profile.title}"}

  def lane_of(:owner, lead),
    do: {lead.owner_user_id, Person.view(lead.owner_user).name}

  def lane_of(:source, lead), do: {to_string(lead.job.source), source_name(lead.job.source)}

  defp source_name(nil), do: "Other"

  defp source_name(source),
    do: source |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp split(nil), do: []
  defp split(value) when is_list(value), do: Enum.flat_map(value, &split/1)

  defp split(value),
    do:
      value
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
