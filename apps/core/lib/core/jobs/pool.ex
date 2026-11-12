defmodule Core.Jobs.Pool do
  @moduledoc """
  `GET /jobs?team_id&…` (AQ-03 §7.1, AQ-03B §5.1): **one team's pool**, the
  list's parameters read and checked, a keyset page of 50 rows, and an
  opaque cursor. `team_id` is required (422 without it; 404 for a team the
  caller is not in, unless an admin); a member whose team's `peer_jobs` is
  `hidden` lists only their own jobs. Every other parameter is optional; a
  value off its vocabulary is a field error (422), never a silent "all".

  | Parameter | Rule |
  |---|---|
  | `team_id` | required: the team whose pool this is |
  | `q` | title or company name, substring or trigram, case- and accent-insensitive |
  | `source` `engagement` `workplace` `remote_scope` `status` | comma-separated keys, any of them |
  | `country` | `allowed_countries` holds it, or the job is remote worldwide |
  | `skills` | comma-separated skill ids, any of them |
  | `money_min_minor` + `currency` + `period` | QP3-9; all three or none. `currency` alone is the money sort's |
  | `posted_within` | 1 · 3 · 7 · 14 · 30 days: `posted_on`, else `first_seen_at` |
  | `archived` | `true`: only archived; otherwise only live |
  | `suggested_for` | a profile id: jobs scoring ≥ 70 for it and not dismissed, best first |
  | `has_leads` | `true` · `false`: a job with a lead, or none (AQ-04A §8.1) |
  | `not_applied_with` | a profile id: no lead past To do for it on the posting, in any team |
  | `sort` | `newest` (default) · `posted` · `money` (needs `currency`); ties by id |
  | `cursor` | the last page's `next_cursor` |
  """

  alias Core.Access
  alias Core.Access.Jobs, as: JobAccess
  alias Core.Jobs
  alias Core.Jobs.{Sheet, Suggest}
  alias Data.Companies.Company
  alias Data.JobList
  alias Data.JobParts
  alias Data.Leads, as: LeadStore
  alias Data.Profiles
  alias Data.Scope
  alias Data.Vocabulary

  @page 50
  @within ~w(1 3 7 14 30)
  @lists [
    {"source", :sources, Vocabulary.job_sources()},
    {"engagement", :engagements, Vocabulary.engagement_types()},
    {"workplace", :workplaces, Vocabulary.workplace_types()},
    {"remote_scope", :remote_scopes, Vocabulary.remote_scopes()},
    {"status", :statuses, Vocabulary.job_statuses()}
  ]

  @doc "A page: `{:ok, %{items: [row], next_cursor}}`."
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :read, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, filters} <- filters(params, now),
         {:ok, filters} <- lead_filters(scope, filters, params),
         filters = Map.put(filters, :visible_to, visible_to(scope, team.id)),
         {:ok, sort} <- sort(params, filters),
         {:ok, profile} <- suggested_for(scope, params["suggested_for"]),
         sort = if(profile, do: :suggested, else: sort),
         {:ok, cursor} <- decode(params["cursor"], sort) do
      profiles = Sheet.profiles(scope, team.id)
      {jobs, next} = page(team.id, filters, sort, cursor, profile, now)
      best = Sheet.best(jobs, profiles, now)
      {:ok, %{items: Enum.map(jobs, &Sheet.row(&1, Map.get(best, &1.id))), next_cursor: next}}
    end
  end

  # `{user_id, peers?}` for `Data.JobList`: a member at `hidden` lists their own.
  defp visible_to(scope, team_id) do
    case JobAccess.pool_reach(scope, team_id) do
      {:own, me} -> {me, false}
      _all -> :all
    end
  end

  defp page(team_id, filters, :suggested, cursor, profile, now) do
    dismissed = MapSet.new(JobParts.dismissed_jobs(profile.id))

    scored =
      team_id
      |> JobList.all(filters)
      |> Enum.reject(&MapSet.member?(dismissed, &1.id))
      |> Enum.map(&{Suggest.score(profile, &1, now).score, &1})
      |> Enum.filter(fn {score, _job} -> score >= Suggest.threshold() end)
      |> Enum.sort_by(fn {score, job} -> {-score, reverse(job.id)} end)
      |> Enum.drop_while(fn {score, job} -> not after?({score, job.id}, cursor) end)

    {rows, more} = Enum.split(scored, @page)

    next =
      if more == [],
        do: nil,
        else: rows |> List.last() |> then(fn {s, j} -> encode(:suggested, s, j.id) end)

    {Enum.map(rows, &elem(&1, 1)), next}
  end

  defp page(team_id, filters, sort, cursor, _profile, _now) do
    jobs = JobList.page(team_id, filters, sort, cursor, @page)
    {rows, more} = Enum.split(jobs, @page)

    next =
      if more == [],
        do: nil,
        else: encode(sort, key(sort, List.last(rows), filters), List.last(rows).id)

    {rows, next}
  end

  # Ids descending, as the SQL's tie-break: sorting by the inverted bytes.
  defp reverse(id), do: id |> Ecto.UUID.dump!() |> :binary.bin_to_list() |> Enum.map(&(255 - &1))

  defp after?(_entry, nil), do: true

  defp after?({score, id}, {c_score, c_id}),
    do: score < c_score or (score == c_score and reverse(id) > reverse(c_id))

  defp key(:newest, job, _filters), do: job.first_seen_at
  defp key(:posted, job, _filters), do: job.posted_on
  defp key(:money, job, filters), do: JobList.money_key(job, filters.money_sort)

  # ── Parameters ──────────────────────────────────────────────────────────────

  defp filters(params, now) do
    steps = [
      &lists(&1, params),
      &country(&1, params["country"]),
      &skills(&1, params["skills"]),
      &money(&1, params),
      &posted_within(&1, params["posted_within"], now)
    ]

    base = %{
      q: Company.normalize(Utils.presence(params["q"])),
      archived: params["archived"] in [true, "true"]
    }

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

  defp country(acc, nil), do: {:ok, acc}

  defp country(acc, code) do
    code = code |> to_string() |> String.trim() |> String.upcase()

    if code =~ ~r/^[A-Z]{2}$/,
      do: {:ok, Map.put(acc, :country, code)},
      else: invalid("country", "is not an ISO country code")
  end

  defp skills(acc, value) do
    ids = Enum.map(split(value), &Ecto.UUID.cast/1)

    if Enum.all?(ids, &match?({:ok, _id}, &1)),
      do: {:ok, Map.put(acc, :skill_ids, Enum.map(ids, &elem(&1, 1)))},
      else: invalid("skills", "has an id that is not a skill's")
  end

  defp money(acc, params) do
    min = Utils.presence(to_text(params["money_min_minor"]))

    currency =
      params["currency"] |> to_text() |> Utils.presence() |> then(&(&1 && String.upcase(&1)))

    period = Utils.presence(to_text(params["period"]))

    with :ok <- money_shape(currency, period) do
      money_filter(acc, min, currency, period)
    end
  end

  defp money_shape(currency, period) do
    cond do
      currency && not (currency =~ ~r/^[A-Z]{3}$/) ->
        invalid("currency", "is not an ISO currency code")

      period && period not in Vocabulary.comp_periods() ->
        invalid("period", "is not one of the periods")

      true ->
        :ok
    end
  end

  # `currency` alone is the money sort's; the filter wants all three.
  defp money_filter(acc, nil, currency, nil),
    do: {:ok, Map.put(acc, :money_sort, currency && %{currency: currency, project?: false})}

  defp money_filter(acc, min, currency, period)
       when is_binary(min) and is_binary(currency) and is_binary(period) do
    with {:ok, min} <- minor(min) do
      period = String.to_existing_atom(period)

      {:ok,
       acc
       |> Map.put(:money, %{min: min, currency: currency, period: period})
       |> Map.put(:money_sort, %{currency: currency, project?: period == :project})}
    end
  end

  defp money_filter(_acc, min, currency, period) do
    missing = for {k, nil} <- [money_min_minor: min, currency: currency, period: period], do: k
    {:error, {:invalid, Map.new(missing, &{to_string(&1), ["is needed with the money filter"]})}}
  end

  defp minor(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> {:ok, n}
      _other -> invalid("money_min_minor", "is not a whole amount in minor units")
    end
  end

  defp posted_within(acc, nil, _now), do: {:ok, acc}

  defp posted_within(acc, days, now) do
    days = to_text(days)

    if days in @within do
      since = DateTime.add(now, -String.to_integer(days) * 86_400, :second)
      {:ok, Map.put(acc, :posted_since, {DateTime.to_date(since), since})}
    else
      invalid("posted_within", "is one of 1, 3, 7, 14 or 30 days")
    end
  end

  defp sort(params, filters) do
    case params["sort"] do
      nil ->
        {:ok, :newest}

      "newest" ->
        {:ok, :newest}

      "posted" ->
        {:ok, :posted}

      "money" ->
        if filters.money_sort,
          do: {:ok, :money},
          else: invalid("currency", "is needed to sort by money")

      _other ->
        invalid("sort", "is newest, posted or money")
    end
  end

  defp lead_filters(scope, filters, params) do
    with {:ok, has} <- has_leads(params["has_leads"]),
         {:ok, keys} <- not_applied(scope, params["not_applied_with"]) do
      {:ok, filters |> Map.put(:has_leads, has) |> Map.put(:not_applied_keys, keys)}
    end
  end

  defp has_leads(nil), do: {:ok, nil}
  defp has_leads(value) when value in [true, "true"], do: {:ok, true}
  defp has_leads(value) when value in [false, "false"], do: {:ok, false}
  defp has_leads(_value), do: invalid("has_leads", "is true or false")

  defp not_applied(_scope, nil), do: {:ok, nil}

  defp not_applied(scope, id) do
    with {:ok, profile} <- suggested_for(scope, id),
         do: {:ok, LeadStore.applied_keys(Scope.organisation_id(scope), profile.id)}
  end

  defp suggested_for(_scope, nil), do: {:ok, nil}

  defp suggested_for(scope, id) do
    with %{} = profile <- Profiles.get(id) || {:error, :not_found},
         true <-
           profile.customer.organisation_id == Scope.organisation_id(scope) ||
             {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:profile, profile}) do
      {:ok, profile}
    end
  end

  # ── The cursor: opaque to the client ────────────────────────────────────────

  defp encode(sort, key, id),
    do: Base.url_encode64(Jason.encode!([Atom.to_string(sort), plain(key), id]), padding: false)

  defp plain(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp plain(%Date{} = on), do: Date.to_iso8601(on)
  defp plain(value), do: value

  defp decode(nil, _sort), do: {:ok, nil}

  defp decode(cursor, sort) do
    tag = Atom.to_string(sort)

    with {:ok, json} <- Base.url_decode64(to_text(cursor), padding: false),
         {:ok, [^tag, key, id]} <- Jason.decode(json),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, key} <- unplain(sort, key) do
      {:ok, {key, id}}
    else
      _invalid -> invalid("cursor", "is not a cursor of this list")
    end
  end

  defp unplain(:newest, at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {:ok, at}
      error -> error
    end
  end

  defp unplain(:posted, nil), do: {:ok, nil}
  defp unplain(:posted, on) when is_binary(on), do: Date.from_iso8601(on)
  defp unplain(:money, value) when is_integer(value) or is_nil(value), do: {:ok, value}
  defp unplain(:suggested, value) when is_integer(value), do: {:ok, value}
  defp unplain(_sort, _key), do: :error

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp split(nil), do: []
  defp split(value) when is_list(value), do: Enum.flat_map(value, &split/1)

  defp split(value),
    do:
      value
      |> to_text()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp to_text(nil), do: nil
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
