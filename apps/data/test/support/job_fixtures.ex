defmodule Data.Fixtures.Jobs do
  @moduledoc """
  The job pool's fixtures (AQ-03 §11), reached through `Data.Fixtures`
  (`company_fixture/2`, `job_fixture/2`), which delegates here because one
  file of every fixture would pass the 500-line cap. Like the rest, they
  take a scope or an organisation and write through `Data.*`.
  """

  alias Data.Companies
  alias Data.JobParts
  alias Data.Jobs
  alias Data.Scope

  @doc """
  `params` naming the scope's first team (`Data.Fixtures.default_team/1`) as
  `team_id`, as the console sends it with a list, a check or a new job.
  """
  def in_team(params, %Scope{} = scope) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("team_id", Data.Fixtures.default_team(scope))
  end

  defp team_id(scope, nil), do: Data.Fixtures.default_team(scope)
  defp team_id(_scope, %{id: id}), do: id

  @doc "A company of `organisation`."
  def company_fixture(organisation, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    base = %{organisation_id: organisation.id, name: "Company #{n}"}
    {:ok, company} = attrs |> Enum.into(base) |> Companies.create()
    company
  end

  @doc """
  A job added by `scope`'s person, through `Data.Jobs`, in `team:` (a
  struct) or the scope's first team by name (`Data.Fixtures.default_team/1`).
  Attrs are the columns, plus `url:` (a company-site link by default),
  `company:` (a struct), `skills:` (`[{skill, required?}]`), `platform_details:` (the
  source's row), `status: :closed` and `archived: true`.
  """
  def job_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    n = System.unique_integer([:positive])
    url = attrs[:url] || "https://careers.example.com/jobs/#{n}"
    {:ok, link} = Utils.JobKey.parse(url)
    at = attrs[:first_seen_at] || DateTime.utc_now()

    identity = %{
      organisation_id: Scope.organisation_id(scope),
      team_id: team_id(scope, attrs[:team]),
      created_by_user_id: Scope.user_id(scope),
      source: link.source,
      source_url: url,
      canonical_key: link.key,
      source_job_id: link.source_job_id,
      first_seen_at: at,
      last_seen_at: at
    }

    {:ok, job} =
      attrs
      |> Map.drop([:url, :team, :company, :skills, :platform_details, :status, :archived])
      |> Enum.into(%{title: "Job #{n}", company_id: attrs[:company] && attrs[:company].id})
      |> Map.merge(identity)
      |> Jobs.create()

    skills =
      for {skill, required?} <- attrs[:skills] || [],
          do: %{skill_id: skill.id, is_required: required?}

    :ok = JobParts.put_skills(job, skills)

    if attrs[:platform_details],
      do: {:ok, _row} = JobParts.put_details(job, attrs[:platform_details])

    closed = %{status: :closed, closed_at: at, close_reason: :filled}
    if attrs[:status] == :closed, do: {:ok, _job} = Jobs.close(job, closed)
    if attrs[:archived], do: {:ok, _job} = Jobs.archive(job, at, Scope.user_id(scope))
    Jobs.reload(job)
  end
end
