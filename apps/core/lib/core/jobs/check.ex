defmodule Core.Jobs.Check do
  @moduledoc """
  The check (AQ-03 §6.3, `POST /jobs/check {team_id, url, …}`): is this link
  a job, and is it in **this team's pool** already (AQ-03B §5.1; another
  team's copy is never named, QT-11)? It answers in this order:

  | State | When |
  |---|---|
  | `invalid` | `Utils.JobKey` says `:not_a_link` or `:not_a_job` |
  | `in_pool` | the key is a job's — archived or closed as it is |
  | `in_pool` + `merged_from` | the key is in `job_merges`: the survivor (QP3-8) |
  | `new` | neither; `similar` holds the team's similar postings the caller sees |

  An `in_pool` answer carries `hidden`: `true` when the job is a teammate's
  the caller may not see (`peer_jobs` `hidden`) — then `job` and
  `merged_from` are `null` and the banner reads "Already in this team's
  pool, added by another member." — else `false`.

  **Similar** is the prototype's rule: the same company (by id, or by the
  normalised name sent), a title sharing ≥ 60% of its words
  (`Utils.JobKey.similar_title?/2`), first seen within
  `organisation_settings.similar_window_days`; live jobs only. Empty until
  a title and a company are sent.

  **The lead half** (AQ-04A §6, §8.3, QP3-1): given a `profile_id`, the
  `in_pool` and `new` answers gain `lead: {answer, existing?, same_customer}`,
  `Core.Leads.Guard`'s, across every team; without one, `lead` is `null`.

  `existing/2` is the half `Core.Jobs.create/3` runs again inside its
  transaction, so a link that became a job meanwhile is `job_exists`.
  """

  alias Core.Access
  alias Core.Jobs
  alias Core.Jobs.Sheet
  alias Core.Leads
  alias Core.Leads.Guard
  alias Data.Companies
  alias Data.Jobs, as: Store
  alias Data.Organisations
  alias Data.Scope
  alias Utils.JobKey

  @doc "`POST /jobs/check {team_id, url, title?, company_id?, company_name?, profile_id?}`."
  @spec run(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- Access.why_not(scope, :check, {:job, %{}}),
         {:ok, team} <- Jobs.team(scope, params),
         :ok <- Access.why_not(scope, :check, {:job, %{team_id: team.id}}),
         {:ok, profile} <- profile(scope, params["profile_id"]) do
      case JobKey.parse(params["url"]) do
        {:error, reason} ->
          {:ok, %{state: "invalid", reason: Atom.to_string(reason)}}

        {:ok, %{key: key, source: source}} ->
          answer = answer(scope, team.id, key, source, params, now)
          {:ok, Map.put(answer, :lead, lead_half(scope, key, team.id, profile))}
      end
    end
  end

  defp profile(_scope, nil), do: {:ok, nil}
  defp profile(_scope, ""), do: {:ok, nil}
  defp profile(scope, id), do: Leads.profile(scope, id)

  defp lead_half(_scope, _key, _team_id, nil), do: nil

  defp lead_half(scope, key, team_id, profile),
    do: scope |> Guard.assess(key, team_id, profile) |> Map.delete(:lead)

  defp answer(scope, team_id, key, source, params, now) do
    profiles = Sheet.profiles(scope, team_id)

    case existing(team_id, key) do
      {:job, job} ->
        in_pool(scope, key, source, job, nil, profiles, now)

      {:merged, job, merge} ->
        in_pool(scope, key, source, job, merge, profiles, now)

      :none ->
        similar =
          scope
          |> similar(team_id, params, now)
          |> Enum.filter(&Access.can?(scope, :read, {:job, &1}))
          |> Enum.map(&row(&1, profiles, now))

        %{state: "new", key: key, source: source, similar: similar}
    end
  end

  # The job, or — for a teammate's the caller may not see — only that the
  # team holds it.
  defp in_pool(scope, key, source, job, merge, profiles, now) do
    if Access.can?(scope, :read, {:job, job}) do
      %{
        state: "in_pool",
        key: key,
        source: source,
        job: row(job, profiles, now),
        hidden: false,
        merged_from: merge && %{title: merge.from_title, at: merge.merged_at}
      }
    else
      %{state: "in_pool", key: key, source: source, job: nil, hidden: true, merged_from: nil}
    end
  end

  @doc """
  Whether `key` is in a team's pool: `{:job, job}`, `{:merged, survivor,
  merge}` when a merge kept it, or `:none`.
  """
  @spec existing(binary(), String.t()) :: {:job, map()} | {:merged, map(), map()} | :none
  def existing(team_id, key) do
    case Store.get_by_key(team_id, key) do
      nil ->
        case Store.merge_for_key(team_id, key) do
          nil -> :none
          merge -> {:merged, merge.into_job, merge}
        end

      job ->
        {:job, job}
    end
  end

  @doc false
  # The team's similar postings for a title and a company sent with a link.
  def similar(scope, team_id, params, now) do
    org_id = Scope.organisation_id(scope)
    title = Utils.presence(params["title"])
    company_ids = company_ids(org_id, params)

    if is_nil(title) or company_ids == [] do
      []
    else
      days = Organisations.get_settings(org_id).similar_window_days
      since = DateTime.add(now, -days * 86_400, :second)

      team_id
      |> Store.seen_since(company_ids, since)
      |> Enum.filter(&JobKey.similar_title?(&1.title, title))
    end
  end

  defp company_ids(org_id, params) do
    by_id =
      case Utils.presence(params["company_id"]) && Companies.get(org_id, params["company_id"]) do
        %{id: id} -> [id]
        _none -> []
      end

    by_name =
      case Companies.get_by_name(org_id, Utils.presence(params["company_name"])) do
        %{id: id} -> [id]
        nil -> []
      end

    Enum.uniq(by_id ++ by_name)
  end

  defp row(job, profiles, now),
    do: Sheet.row(job, Map.get(Sheet.best([job], profiles, now), job.id))
end
