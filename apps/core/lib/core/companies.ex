defmodule Core.Companies do
  @moduledoc """
  Companies (AQ-03 QP3-6): the job form's picker, the card on a job, its
  edit sheet. Any staff member adds and edits one (§4.2); the customer
  reaches none (`Core.Access`, `{:company, _}`). A name is one company per
  organisation, compared normalised ("bamboo invest" is *Bamboo Invest*);
  every write is audited in its transaction. The list, contacts and merge
  are P6's. Companies are the organisation's, not a team's (QT-2); the
  card's `open_jobs` lists only the open jobs of the teams the caller is in
  (an admin: every team) that the caller may see (AQ-03B §5.1).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Tasks.Person
  alias Data.Companies, as: Store
  alias Data.Companies.Company
  alias Data.Repo
  alias Data.Scope

  @audited ~w(name domain website_url linkedin_url size_band industry hq_country notes_md)a

  @doc "`GET /companies?q`: at most 20, by name, `[{id, name, domain}]`."
  @spec search(Scope.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def search(%Scope{} = scope, q) do
    with :ok <- Access.why_not(scope, :read, {:company, %{}}) do
      {:ok,
       scope
       |> Scope.organisation_id()
       |> Store.search(q)
       |> Enum.map(&%{id: &1.id, name: &1.name, domain: &1.domain})}
    end
  end

  @doc "`GET /companies/:id`: the card, with its open jobs."
  @spec get(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, company} <- fetch(scope, :read, id), do: {:ok, view(scope, company)}
  end

  @doc "`POST /companies`: a new company, audited; a name already taken is a field error."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :create, {:company, %{}}),
         {:ok, company} <- Repo.transaction(fn -> insert(scope, params, now) end),
         do: {:ok, view(scope, company)}
  end

  @doc "`PATCH /companies/:id`: any of its fields, audited with what changed."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, company} <- fetch(scope, :update, id),
         {:ok, updated} <- Repo.transaction(fn -> save(scope, company, params, now) end),
         do: {:ok, view(scope, updated)}
  end

  @doc "The company behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Company.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Company{} = company <-
           Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:company, company}),
         do: {:ok, company}
  end

  @doc false
  # Inside a transaction: the company named `name` (normalised), else a new
  # one with `website_url` — the job form's `company: {name, website_url?}`
  # — and the extension's `linkedin_url` (AQ-05 §10.1).
  def find_or_insert(%Scope{} = scope, %{} = params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    case Store.get_by_name(Scope.organisation_id(scope), params["name"]) do
      %Company{} = company -> company
      nil -> insert(scope, Map.take(params, ["name", "website_url", "linkedin_url"]), now)
    end
  end

  defp insert(scope, params, now) do
    attrs =
      params
      |> fields()
      |> Map.merge(%{
        "organisation_id" => Scope.organisation_id(scope),
        "created_by_user_id" => Scope.user_id(scope)
      })

    case Store.create(attrs) do
      {:ok, company} ->
        {:ok, _event} =
          Audit.record(scope, "created", company, after: snapshot(company), now: now)

        company

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp save(scope, company, params, now) do
    case Store.update(company, fields(params)) do
      {:ok, updated} ->
        {before, after_} = changed(company, updated)

        if before != %{} do
          {:ok, _event} =
            Audit.record(scope, "updated", updated, before: before, after: after_, now: now)
        end

        updated

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp fields(params) do
    params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(Enum.map(Company.fields(), &to_string/1))
  end

  defp changed(old, new) do
    old_map = snapshot(old)
    new_map = snapshot(new)
    keys = for {k, v} <- new_map, old_map[k] != v, do: k
    {Map.take(old_map, keys), Map.take(new_map, keys)}
  end

  defp snapshot(company), do: Audit.snapshot(company, @audited)

  @doc """
  The company as the card shows it to `scope` (AQ-03 §7.1), with the open
  jobs of the caller's teams they may see; `nil` for none.
  """
  @spec view(Scope.t(), Company.t() | nil) :: map() | nil
  def view(_scope, nil), do: nil

  def view(%Scope{} = scope, %Company{} = company) do
    company = Repo.preload(company, created_by_user: [person: :photo])

    %{
      id: company.id,
      name: company.name,
      domain: company.domain,
      website_url: company.website_url,
      linkedin_url: company.linkedin_url,
      size_band: company.size_band,
      industry: company.industry,
      hq_country: company.hq_country,
      notes_md: company.notes_md,
      open_jobs: open_jobs(scope, company),
      created_by: Person.view(company.created_by_user),
      inserted_at: company.inserted_at
    }
  end

  defp open_jobs(scope, company) do
    teams = if Scope.admin?(scope), do: :all, else: Scope.team_ids(scope)

    company.id
    |> Store.open_jobs(teams)
    |> Enum.filter(&Access.can?(scope, :read, {:job, &1}))
    |> Enum.map(&Map.take(&1, [:id, :title]))
  end
end
