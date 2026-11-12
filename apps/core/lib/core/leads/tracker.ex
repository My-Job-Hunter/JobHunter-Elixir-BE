defmodule Core.Leads.Tracker do
  @moduledoc """
  The Tracker (AQ-04B §8.1, §8.4, §9, QP4b-15, QP4b-18): **every lead of the
  current team as one sheet**, by the team's `peer_leads` (a member at
  `hidden` sees their own), with the board's filters plus `label`,
  `missing` (`money`, `cv`) and `state`; `group` (`tracker_groups`), `sort`
  (`tracker_columns`), `dir` (`asc` · `desc`), `cursor`. Keyset pages of
  50 with the `total`; when grouped, the groups with their counts over
  every matching row (rows run group by group, each sorted).

  The rows are made from one read of the team's matching leads (a team's
  worth) and their signals (`Core.Leads.Signals`), then sorted here, so a
  column computed on read — *Next*, labels, *Missing* — sorts like any
  other. `cursor` is the last row seen (its id and place), so *More*
  continues after it even when a row moved meanwhile.

  `csv/3` (`GET /tracker.csv`) is the same query, every matching row and
  every column (none is hidden from a reader of the team's leads), UTF-8
  with a BOM so it opens in a spreadsheet, money as written with its
  currency — never summed or converted — and the export is audited as
  `tracker_exported`.
  """

  alias Core.Access
  alias Core.Access.Leads, as: LeadAccess
  alias Core.Audit
  alias Core.Jobs
  alias Core.Jobs.Sheet, as: JobSheet
  alias Core.Leads.{Board, Pipelines, Signals, Words}
  alias Core.Retention.Policy
  alias Core.Tasks.Person
  alias Data.Leads, as: Store
  alias Data.Repo
  alias Data.Scope
  alias Data.Vocabulary

  @page 50
  @state_order %{todo: 0, in_progress: 1, on_hold: 2, done: 3}
  @missing ~w(money cv)
  @headers %{
    "applied" => "Applied",
    "title" => "Title",
    "company" => "Company",
    "source" => "Source",
    "customer" => "Customer",
    "profile" => "Profile",
    "owner" => "Owner",
    "state" => "State",
    "outcome" => "Outcome",
    "next" => "Next",
    "last_activity" => "Last activity",
    "money" => "Money",
    "workplace" => "Workplace",
    "engagement" => "Engagement",
    "cv" => "CV",
    "labels" => "Labels",
    "missing" => "Missing"
  }

  # ── The page ────────────────────────────────────────────────────────────────

  @doc "`GET /tracker`: `{items, next_cursor, total, groups}`."
  @spec page(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, %{rows: rows, group: group}} <- rows(scope, params, now),
         {:ok, start} <- cursor(rows, params["cursor"]) do
      {items, rest} = rows |> Enum.drop(start) |> Enum.split(@page)

      {:ok,
       %{
         items: items,
         next_cursor: if(rest == [], do: nil, else: encode(List.last(items), start + @page - 1)),
         total: length(rows),
         groups: groups(group, rows)
       }}
    end
  end

  # ── The CSV ─────────────────────────────────────────────────────────────────

  @doc "`GET /tracker.csv`: `{:ok, csv, filename}`, audited."
  @spec csv(Scope.t(), map(), DateTime.t()) :: {:ok, iodata(), String.t()} | {:error, term()}
  def csv(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, %{rows: rows, team: team}} <- rows(scope, params, now) do
      zone = Signals.zone(scope.organisation)
      columns = Vocabulary.tracker_columns()

      lines = [
        Enum.map(columns, &Map.fetch!(@headers, &1)),
        Enum.map(rows, fn row -> Enum.map(columns, &cell(&1, row, zone)) end)
      ]

      body = ["﻿" | Enum.map([hd(lines) | List.last(lines)], &line/1)]

      {:ok, _audit} =
        Audit.record(scope, "tracker_exported", team,
          after: %{
            "team_id" => team.id,
            "rows" => length(rows),
            "query" => params |> Map.drop(~w(team team_id cursor)) |> URI.encode_query()
          },
          now: now
        )

      {:ok, body, "tracker-#{slug(team.name)}-#{Policy.day(now, zone)}.csv"}
    end
  end

  defp line(cells), do: [Enum.map_join(cells, ",", &escape/1), "\r\n"]

  # RFC 4180 quoting; a cell that a spreadsheet would read as a formula is
  # kept as text.
  defp escape(nil), do: ""

  defp escape(value) do
    text = to_string(value)
    text = if String.starts_with?(text, ~w(= + - @)), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  defp cell("applied", r, zone), do: r.applied_at && Policy.day(r.applied_at, zone)
  defp cell("title", r, _zone), do: r.title
  defp cell("company", r, _zone), do: r.company && r.company.name
  defp cell("source", r, _zone), do: Words.value(r.source)
  defp cell("customer", r, _zone), do: r.customer.display_name
  defp cell("profile", r, _zone), do: r.profile.title
  defp cell("owner", r, _zone), do: r.owner && r.owner.name

  defp cell("state", r, _zone),
    do: Words.place(r.state, stage_name(r), r.outcome)

  defp cell("outcome", r, _zone), do: Words.outcome(r.outcome)
  defp cell("next", r, _zone), do: r.next && r.next.words
  defp cell("last_activity", r, zone), do: Policy.day(r.last_activity_at, zone)
  defp cell("money", r, _zone), do: Utils.Money.line(r.money)
  defp cell("workplace", r, _zone), do: Words.value(r.workplace)
  defp cell("engagement", r, _zone), do: Words.value(r.engagement)
  defp cell("cv", r, _zone), do: r.cv && "#{r.cv.label} v#{r.cv.version}"
  defp cell("labels", r, _zone), do: Enum.map_join(r.labels, ", ", & &1.name)
  defp cell("missing", r, _zone), do: Enum.join(r.missing, ", ")

  defp stage_name(%{stage: %{name: name}}), do: name
  defp stage_name(_row), do: nil

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  # ── The rows ────────────────────────────────────────────────────────────────

  defp rows(scope, params, now) do
    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, filters} <- Board.filters(scope, team, params, now),
         {:ok, filters} <- pipeline(filters, params["pipeline"]),
         {:ok, missing} <- missing(params["missing"]),
         {:ok, group} <- choice(params["group"], Vocabulary.tracker_groups(), "group", "none"),
         {:ok, sort} <- choice(params["sort"], Vocabulary.tracker_columns(), "sort", nil),
         {:ok, dir} <- dir(params["dir"], sort) do
      reach = LeadAccess.board_reach(scope, team.id)
      visible = if match?({:own, _}, reach), do: elem(reach, 1), else: :all

      leads =
        team.id
        |> Store.for_team(Map.put(filters, :visible_to, visible))
        |> Repo.preload(:document)

      ctx = Signals.context(scope.organisation, leads, now)

      rows =
        leads
        |> Enum.map(&row(&1, Signals.for_lead(ctx, &1)))
        |> Enum.filter(&(missing == [] or Enum.any?(missing, fn m -> m in &1.missing end)))
        |> order(group, sort || "last_activity", dir)

      {:ok, %{rows: rows, group: group, team: team}}
    end
  end

  @doc "A Tracker row (§8.4) of a lead read with its card's preloads and `document`."
  @spec row(map(), map()) :: map()
  def row(lead, signals) do
    job = lead.job
    money = JobSheet.money(job)

    %{
      id: lead.id,
      applied_at: lead.applied_at,
      title: job.title,
      company: job.company && %{id: job.company.id, name: job.company.name},
      source: job.source,
      customer: %{id: lead.profile.customer.id, display_name: lead.profile.customer.display_name},
      profile: %{id: lead.profile.id, title: lead.profile.title},
      owner: Person.view(lead.owner_user),
      state: lead.state,
      stage: Pipelines.stage(lead.stage),
      outcome: lead.outcome,
      next: signals.next,
      last_activity_at: lead.last_activity_at,
      quiet: Map.take(signals.quiet, [:archives_on, :warn]),
      money: money,
      workplace: job.workplace,
      engagement: job.engagement,
      cv: lead.document && cv(lead.document),
      labels: signals.labels,
      missing:
        Enum.filter(@missing, fn
          "money" -> is_nil(money.min_minor) and is_nil(money.max_minor)
          "cv" -> is_nil(lead.document_id)
        end)
    }
  end

  defp cv(document), do: %{id: document.id, label: document.label, version: document.version_no}

  # ── Order, groups, the cursor ───────────────────────────────────────────────

  defp order(rows, group, sort, dir) do
    Enum.sort(rows, fn a, b ->
      ga = group_key(group, a)
      gb = group_key(group, b)

      if ga != gb,
        do: ga < gb,
        else: before?(sort_key(sort, a), sort_key(sort, b), dir, a.id, b.id)
    end)
  end

  # Nothing sorts last, whichever way; ties go by id so pages never overlap.
  defp before?(nil, nil, _dir, a, b), do: a <= b
  defp before?(nil, _b, _dir, _ia, _ib), do: false
  defp before?(_a, nil, _dir, _ia, _ib), do: true
  defp before?(a, a, _dir, ia, ib), do: ia <= ib
  defp before?(a, b, :asc, _ia, _ib), do: a < b
  defp before?(a, b, :desc, _ia, _ib), do: a > b

  defp sort_key("applied", r), do: at(r.applied_at)
  defp sort_key("title", r), do: down(r.title)
  defp sort_key("company", r), do: r.company && down(r.company.name)
  defp sort_key("source", r), do: r.source && to_string(r.source)
  defp sort_key("customer", r), do: down(r.customer.display_name)
  defp sort_key("profile", r), do: down(r.profile.title)
  defp sort_key("owner", r), do: r.owner && down(r.owner.name)

  defp sort_key("state", r),
    do: {Map.fetch!(@state_order, r.state), (r.stage && r.stage.position) || 0}

  defp sort_key("outcome", r), do: r.outcome && to_string(r.outcome)
  defp sort_key("next", r), do: r.next && at(r.next.at)
  defp sort_key("last_activity", r), do: at(r.last_activity_at)

  defp sort_key("money", %{money: %{currency: c} = m}) when is_binary(c),
    do: {c, m.min_minor || m.max_minor}

  defp sort_key("money", _r), do: nil
  defp sort_key("workplace", r), do: r.workplace && to_string(r.workplace)
  defp sort_key("engagement", r), do: r.engagement && to_string(r.engagement)
  defp sort_key("cv", r), do: r.cv && {down(r.cv.label), r.cv.version}
  defp sort_key("labels", %{labels: []}), do: nil
  defp sort_key("labels", r), do: r.labels |> Enum.map_join(", ", & &1.name) |> down()
  defp sort_key("missing", r), do: length(r.missing)

  defp group_key("none", _r), do: 0
  defp group_key("state", r), do: Map.fetch!(@state_order, r.state)

  defp group_key("stage", r),
    do: {Map.fetch!(@state_order, r.state), (r.stage && r.stage.position) || 0}

  defp group_key("customer", r), do: {down(r.customer.display_name), r.customer.id}
  defp group_key("profile", r), do: {down(r.customer.display_name), down(r.profile.title)}
  defp group_key("owner", r), do: {r.owner && down(r.owner.name), r.owner && r.owner.user_id}
  defp group_key("source", r), do: to_string(r.source)

  defp groups("none", _rows), do: nil

  defp groups(group, rows) do
    rows
    |> Enum.chunk_by(&group_key(group, &1))
    |> Enum.map(fn [first | _] = held ->
      {key, name} = group_of(group, first)
      %{key: key, name: name, count: length(held)}
    end)
  end

  defp group_of("state", r), do: {to_string(r.state), Words.state(r.state)}

  # By state and stage: "Done · Applied" holds every outcome reached there.
  defp group_of("stage", %{stage: %{key: key, name: name}} = r),
    do: {"#{r.state}:#{key}", Words.state(r.state) <> " · " <> name}

  defp group_of("stage", r), do: {to_string(r.state), Words.state(r.state)}
  defp group_of("customer", r), do: {r.customer.id, r.customer.display_name}

  defp group_of("profile", r),
    do: {r.profile.id, "#{r.customer.display_name} · #{r.profile.title}"}

  defp group_of("owner", r), do: {r.owner && r.owner.user_id, r.owner && r.owner.name}
  defp group_of("source", r), do: {to_string(r.source), Words.value(r.source)}

  defp encode(row, index), do: Base.url_encode64("#{row.id}|#{index}", padding: false)

  defp cursor(_rows, nil), do: {:ok, 0}
  defp cursor(_rows, ""), do: {:ok, 0}

  defp cursor(rows, value) do
    with {:ok, decoded} <- Base.url_decode64(to_string(value), padding: false),
         [id, index] <- String.split(decoded, "|", parts: 2),
         {index, ""} <- Integer.parse(index) do
      case Enum.find_index(rows, &(&1.id == id)) do
        nil -> {:ok, index + 1}
        at -> {:ok, at + 1}
      end
    else
      _bad -> invalid("cursor", "is not a cursor")
    end
  end

  # ── Parameters ──────────────────────────────────────────────────────────────

  defp pipeline(filters, nil), do: {:ok, filters}
  defp pipeline(filters, ""), do: {:ok, filters}

  defp pipeline(filters, key) do
    if to_string(key) in Vocabulary.pipeline_keys(),
      do: {:ok, Map.put(filters, :pipeline_key, String.to_existing_atom(to_string(key)))},
      else: invalid("pipeline", "is employment or freelance")
  end

  defp missing(nil), do: {:ok, []}

  defp missing(value) do
    values =
      value
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.all?(values, &(&1 in @missing)),
      do: {:ok, values},
      else: invalid("missing", "is money or cv")
  end

  defp choice(nil, _allowed, _field, default), do: {:ok, default}
  defp choice("", _allowed, _field, default), do: {:ok, default}

  defp choice(value, allowed, field, _default) do
    if to_string(value) in allowed,
      do: {:ok, to_string(value)},
      else: invalid(field, "is not one of the list")
  end

  # The default: last activity, newest first; any other column, A→Z.
  defp dir(nil, nil), do: {:ok, :desc}
  defp dir(nil, _sort), do: {:ok, :asc}
  defp dir("", sort), do: dir(nil, sort)
  defp dir("asc", _sort), do: {:ok, :asc}
  defp dir("desc", _sort), do: {:ok, :desc}
  defp dir(_other, _sort), do: invalid("dir", "is asc or desc")

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp down(nil), do: nil
  defp down(text), do: String.downcase(text)

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
