defmodule Data.JobList do
  @moduledoc """
  A team's pool (AQ-03 §7.1, AQ-03B §3.1) as a query: every filter and the
  three sorts, by keyset. Who of the team sees which job is the caller's
  `visible_to`: `:all`, or `{user_id, peers?}` — their own jobs, and the
  team's others too when `peers?` (the team's `peer_jobs` is not hidden). `Core.Jobs.Pool` parses the parameters into the
  `filters` map below and owns the cursor's encoding; this module only
  composes SQL.

  | Filter | Is |
  |---|---|
  | `q` | normalised text: title or company name, substring or trigram (`<%`) |
  | `sources` `engagements` `workplaces` `remote_scopes` `statuses` | atoms, any of them |
  | `country` | an ISO code: `allowed_countries` holds it, or the job is remote worldwide |
  | `skill_ids` | the job has any of them |
  | `money` | `%{min, currency, period}`: the job's top in `currency`, annualised (QP3-9), at least `min` annualised; a project only against a project |
  | `posted_since` | `{date, at}`: `posted_on` from `date`, else `first_seen_at` from `at` |
  | `archived` | only the archived when true, only the live otherwise |
  | `visible_to` | `:all` (the default), or `{user_id, peers?}` as above |
  | `has_leads` | `true`: a job with a lead; `false`: none (AQ-04A §8.1) |
  | `not_applied_keys` | the posting keys a profile applied on, in any team: those jobs left out |

  The money key is `Utils.Units`' factors written as SQL; `Data.JobListTest`
  holds the two to the same numbers.
  """

  import Ecto.Query, warn: false

  alias Data.Jobs
  alias Data.Jobs.{Job, JobSkill, Merge}
  alias Data.Leads.Lead
  alias Data.Repo

  @doc """
  One page: at most `limit` jobs after `cursor` (the sort key and id of the
  last row seen), plus one more when there is a next page. `sort` is
  `:newest`, `:posted` or `:money` (which needs `filters.money_sort`, a
  `%{currency, project?}`).
  """
  @spec page(binary(), map(), atom(), term(), pos_integer()) :: [Job.t()]
  def page(team_id, filters, sort, cursor, limit) do
    team_id
    |> matching(filters)
    |> sorted(sort, filters)
    |> after_cursor(sort, filters, cursor)
    |> limit(^(limit + 1))
    |> preload(^Jobs.base_preload())
    |> Repo.all()
  end

  @doc "Every job the filters match, unsorted: the candidates `suggested_for` scores."
  @spec all(binary(), map()) :: [Job.t()]
  def all(team_id, filters) do
    team_id |> matching(filters) |> preload(^Jobs.base_preload()) |> Repo.all()
  end

  @doc "The money sort's key for one job, as the SQL computes it."
  @spec money_key(Job.t(), map()) :: integer() | nil
  def money_key(%Job{comp_currency: currency} = job, %{currency: currency, project?: project?}) do
    top = job.comp_max_minor || job.comp_min_minor

    cond do
      project? and job.comp_period == :project -> top
      project? -> nil
      true -> Utils.Units.annualise(top, job.comp_period)
    end
  end

  def money_key(_job, _sort), do: nil

  # ── Filters ─────────────────────────────────────────────────────────────────

  defp matching(team_id, filters) do
    from(j in Job, as: :job, where: j.team_id == ^team_id)
    |> visible_to(Map.get(filters, :visible_to, :all))
    |> archived(Map.get(filters, :archived, false))
    |> search(filters[:q])
    |> any_of(:source, filters[:sources])
    |> any_of(:engagement, filters[:engagements])
    |> any_of(:workplace, filters[:workplaces])
    |> any_of(:remote_scope, filters[:remote_scopes])
    |> any_of(:status, filters[:statuses])
    |> country(filters[:country])
    |> skills(filters[:skill_ids])
    |> money(filters[:money])
    |> posted_since(filters[:posted_since])
    |> has_leads(filters[:has_leads])
    |> not_applied(filters[:not_applied_keys])
  end

  # AQ-04A §8.1: a job with a lead (or none), whatever its state.
  defp has_leads(query, nil), do: query

  defp has_leads(query, true),
    do: where(query, [j], exists(from(l in Lead, where: l.job_id == parent_as(:job).id)))

  defp has_leads(query, false),
    do: where(query, [j], not exists(from(l in Lead, where: l.job_id == parent_as(:job).id)))

  # No lead past To do for the profile on the posting, in any team: neither
  # the job's key nor a key merged into it is one the profile applied on.
  defp not_applied(query, nil), do: query
  defp not_applied(query, []), do: query

  defp not_applied(query, keys) do
    merged = from(m in Merge, where: m.from_canonical_key in ^keys, select: m.into_job_id)
    where(query, [j], j.canonical_key not in ^keys and j.id not in subquery(merged))
  end

  defp visible_to(query, {_me, true}), do: query
  defp visible_to(query, {me, false}), do: where(query, [j], j.created_by_user_id == ^me)
  defp visible_to(query, :all), do: query

  defp archived(query, true), do: where(query, [j], not is_nil(j.archived_at))
  defp archived(query, _live), do: where(query, [j], is_nil(j.archived_at))

  defp search(query, nil), do: query
  defp search(query, ""), do: query

  defp search(query, qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"

    query
    |> join(:left, [j], c in assoc(j, :company), as: :company)
    |> where(
      [j, company: c],
      fragment("lower(unaccent(?)) LIKE ?", j.title, ^like) or
        fragment("? <% lower(unaccent(?))", ^qn, j.title) or
        like(c.name_normalized, ^like) or fragment("? <% ?", ^qn, c.name_normalized)
    )
  end

  defp any_of(query, _field, nil), do: query
  defp any_of(query, _field, []), do: query
  defp any_of(query, field, values), do: where(query, [j], field(j, ^field) in ^values)

  defp country(query, nil), do: query

  defp country(query, code) do
    where(
      query,
      [j],
      fragment("? = ANY(?)", ^code, j.allowed_countries) or j.remote_scope == :global
    )
  end

  defp skills(query, nil), do: query
  defp skills(query, []), do: query

  defp skills(query, ids) do
    having = from(s in JobSkill, where: s.skill_id in ^ids, select: s.job_id)
    where(query, [j], j.id in subquery(having))
  end

  defp money(query, nil), do: query

  defp money(query, %{min: min, currency: currency, period: :project}) do
    where(
      query,
      [j],
      j.comp_currency == ^currency and j.comp_period == :project and
        coalesce(j.comp_max_minor, j.comp_min_minor) >= ^min
    )
  end

  defp money(query, %{min: min, currency: currency, period: period}) do
    floor = Utils.Units.annualise(min, period)
    where(query, ^dynamic([j], j.comp_currency == ^currency and ^annual_top() >= ^floor))
  end

  defp posted_since(query, nil), do: query

  defp posted_since(query, {%Date{} = on, %DateTime{} = at}) do
    where(
      query,
      [j],
      (not is_nil(j.posted_on) and j.posted_on >= ^on) or
        (is_nil(j.posted_on) and j.first_seen_at >= ^at)
    )
  end

  # The job's top, as a year's worth; NULL for a project or no money. The
  # factors are `Utils.Units.annual_factors/0`'s.
  defp annual_top do
    dynamic(
      [j],
      fragment(
        "CASE ? WHEN 'hour' THEN ? * 2080 WHEN 'day' THEN ? * 260 WHEN 'week' THEN ? * 52 WHEN 'month' THEN ? * 12 WHEN 'year' THEN ? END",
        j.comp_period,
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor),
        coalesce(j.comp_max_minor, j.comp_min_minor)
      )
    )
  end

  defp money_sort_key(%{currency: currency, project?: true}) do
    dynamic(
      [j],
      fragment(
        "CASE WHEN ? = ? AND ? = 'project' THEN ? END",
        j.comp_currency,
        ^currency,
        j.comp_period,
        coalesce(j.comp_max_minor, j.comp_min_minor)
      )
    )
  end

  defp money_sort_key(%{currency: currency}) do
    dynamic(
      [j],
      fragment("CASE WHEN ? = ? THEN ? END", j.comp_currency, ^currency, ^annual_top())
    )
  end

  # ── Sorts and the keyset ────────────────────────────────────────────────────

  defp sorted(query, :newest, _filters),
    do: order_by(query, [j], desc: j.first_seen_at, desc: j.id)

  defp sorted(query, :posted, _filters),
    do: order_by(query, [j], desc_nulls_last: j.posted_on, desc: j.id)

  defp sorted(query, :money, filters) do
    key = money_sort_key(filters.money_sort)
    order_by(query, ^[desc_nulls_last: key, desc: dynamic([j], j.id)])
  end

  defp after_cursor(query, _sort, _filters, nil), do: query

  defp after_cursor(query, :newest, _filters, {%DateTime{} = at, id}) do
    where(query, [j], j.first_seen_at < ^at or (j.first_seen_at == ^at and j.id < ^id))
  end

  defp after_cursor(query, :posted, _filters, {on, id}),
    do: where(query, ^nullable_after(dynamic([j], j.posted_on), on, id))

  defp after_cursor(query, :money, filters, {value, id}),
    do: where(query, ^nullable_after(money_sort_key(filters.money_sort), value, id))

  # Descending with nulls last: after a value come smaller values, the same
  # value with a smaller id, then every null; after a null, nulls with a
  # smaller id.
  defp nullable_after(key, nil, id), do: dynamic([j], is_nil(^key) and j.id < ^id)

  defp nullable_after(key, value, id) do
    dynamic([j], ^key < ^value or (^key == ^value and j.id < ^id) or is_nil(^key))
  end
end
