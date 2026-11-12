defmodule Core.Leads.Portal do
  @moduledoc """
  The portal's leads (AQ-04A §8.2, QP4a-14), on the scope pinned to the
  customer: **My applications** — their leads from every team serving them,
  each in the customer's view (`Core.Leads.Sheet`), never the team's name —
  and **Suggested for you**, read-only, when a team serving them has
  `customer_sees_job_suggestions` on. *I applied* is
  `Core.Leads.Act.portal_applied/4`; one lead's sheet is `Core.Leads.get/3`.
  """

  alias Core.Jobs.{Sheet, Suggest}
  alias Core.Leads.Sheet, as: LeadSheet
  alias Data.Customers
  alias Data.JobList
  alias Data.JobParts
  alias Data.Leads, as: Store
  alias Data.Profiles
  alias Data.Scope
  alias Data.Teams

  @doc """
  `GET /leads`: `%{todo, in_progress, on_hold, done}` of the customer's lead
  row, archived ones left out; Done newest first, thirty days of it, and
  `older_done` counting the rest (the screen's "Older · N").
  """
  @spec list(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, customer_id} <- customer(scope) do
      rows = customer_id |> Store.for_customer() |> Enum.group_by(& &1.state)
      since = DateTime.add(now, -30 * 86_400, :second)

      {recent, older} =
        rows
        |> Map.get(:done, [])
        |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
        |> Enum.split_with(&(DateTime.compare(&1.finished_at, since) != :lt))

      {:ok,
       %{
         todo: rows(rows, :todo),
         in_progress: rows(rows, :in_progress),
         on_hold: rows(rows, :on_hold),
         done: Enum.map(recent, &LeadSheet.customer_row/1),
         older_done: length(older)
       }}
    end
  end

  defp rows(rows, state), do: rows |> Map.get(state, []) |> Enum.map(&LeadSheet.customer_row/1)

  @doc """
  `GET /suggestions`: for each team serving the customer with
  `customer_sees_job_suggestions` on, that team's live jobs scoring ≥ 70 for
  the customer's live profiles, not dismissed, with no lead for that profile
  on the posting; best first, `[%{job, profile, score}]`. Otherwise `[]`.
  """
  @spec suggestions(Scope.t(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def suggestions(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, customer_id} <- customer(scope) do
      customer = Customers.get(Scope.organisation_id(scope), customer_id)

      teams =
        customer.team_ids
        |> Teams.settings_for()
        |> Enum.filter(fn {_team_id, settings} -> settings.customer_sees_job_suggestions end)
        |> Enum.map(&elem(&1, 0))

      {:ok, if(teams == [], do: [], else: suggested(customer, teams, now))}
    end
  end

  defp suggested(customer, teams, now) do
    profiles =
      customer.id
      |> Profiles.list()
      |> Enum.filter(&(&1.status == :active))

    taken =
      customer.id
      |> Store.for_customer(archived: true)
      |> Enum.map(&{&1.profile_id, &1.job.canonical_key})
      |> MapSet.new()

    jobs = Enum.flat_map(teams, &JobList.all(&1, %{archived: false, statuses: [:open, :unknown]}))

    for profile <- profiles,
        dismissed = MapSet.new(JobParts.dismissed_jobs(profile.id)),
        job <- jobs,
        not MapSet.member?(dismissed, job.id),
        not MapSet.member?(taken, {profile.id, job.canonical_key}),
        score = Suggest.score(profile, job, now).score,
        score >= Suggest.threshold() do
      %{job: job_summary(job), profile: %{id: profile.id, title: profile.title}, score: score}
    end
    |> Enum.sort_by(&{-&1.score, &1.job.id, &1.profile.id})
  end

  # The customer's job summary: no team, no suggestions of the team's.
  defp job_summary(job) do
    %{
      id: job.id,
      title: job.title,
      company: job.company && %{id: job.company.id, name: job.company.name},
      source: job.source,
      workplace: job.workplace,
      engagement: job.engagement,
      money: Sheet.money(job)
    }
  end

  defp customer(scope) do
    case Scope.customer_id(scope) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end
end
