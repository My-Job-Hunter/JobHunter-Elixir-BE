defmodule Data.Companies do
  @moduledoc """
  Companies (AQ-03 §5.1, QP3-6). Storage only: who may add or edit one is
  `Core.Access`'s (`{:company, _}`), the rest `Core.Companies`'s. Every
  read is scoped to the organisation.
  """

  import Ecto.Query, warn: false

  alias Data.Companies.Company
  alias Data.Jobs.Job
  alias Data.Repo

  @preload [created_by_user: [person: :photo]]

  @doc "A company of the organisation, with who added it; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Company.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Company |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> preload_all()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The company whose name normalises to `name`'s, or `nil`."
  @spec get_by_name(binary(), String.t() | nil) :: Company.t() | nil
  def get_by_name(_organisation_id, nil), do: nil

  def get_by_name(organisation_id, name) do
    case Company.normalize(name) do
      "" ->
        nil

      normalized ->
        Company
        |> Repo.get_by(organisation_id: organisation_id, name_normalized: normalized)
        |> preload_all()
    end
  end

  @doc """
  The picker (AQ-03 §7.1): at most 20 companies by name; `q` matches the
  normalised name by prefix, substring or trigram.
  """
  @spec search(binary(), String.t() | nil) :: [Company.t()]
  def search(organisation_id, q) do
    query =
      from(c in Company,
        where: c.organisation_id == ^organisation_id,
        order_by: [asc: c.name_normalized, asc: c.id],
        limit: 20
      )

    case Company.normalize(q || "") do
      "" ->
        Repo.all(query)

      qn ->
        like = "%" <> escape_like(qn) <> "%"

        query
        |> where([c], like(c.name_normalized, ^like) or fragment("? % ?", c.name_normalized, ^qn))
        |> Repo.all()
    end
  end

  @doc """
  The live, open jobs of a company in `team_ids` (`:all` for every team),
  by title: the card's list (AQ-03B §5.1). Each carries what
  `Core.Access` decides a job from.
  """
  @spec open_jobs(binary(), [binary()] | :all) :: [map()]
  def open_jobs(_company_id, []), do: []

  def open_jobs(company_id, team_ids) do
    from(j in Job,
      where: j.company_id == ^company_id and j.status == :open and is_nil(j.archived_at),
      order_by: [asc: j.title, asc: j.id],
      select: %{
        id: j.id,
        title: j.title,
        organisation_id: j.organisation_id,
        team_id: j.team_id,
        created_by_user_id: j.created_by_user_id
      }
    )
    |> then(&if(team_ids == :all, do: &1, else: where(&1, [j], j.team_id in ^team_ids)))
    |> Repo.all()
  end

  @spec create(map()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, company} <- %Company{} |> Company.changeset(attrs) |> Repo.insert(),
         do: {:ok, preload_all(company)}
  end

  @spec update(Company.t(), map()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def update(%Company{} = company, attrs) do
    with {:ok, updated} <- company |> Company.changeset(attrs) |> Repo.update(),
         do: {:ok, preload_all(updated)}
  end

  @doc "`%`, `_` and `\\` taken out of a search term, so it is matched as typed."
  @spec escape_like(String.t()) :: String.t()
  def escape_like(term), do: String.replace(term, ~r/[%_\\]/, "")

  defp preload_all(nil), do: nil
  defp preload_all(company), do: Repo.preload(company, @preload)
end
