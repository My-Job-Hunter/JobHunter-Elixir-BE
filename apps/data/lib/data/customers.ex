defmodule Data.Customers do
  @moduledoc """
  Customers, the teams that serve them and the staff-only notes (JH-01
  §4.3). Storage only: who sees which customer is `Core.Access`'s, and
  every verb's rule is `Core.Customers`'s.

  Every read answers the customer **with `team_ids` filled** (`fill/1`),
  because `Core.Access` decides from it; a customer struct without them is
  one no decision should be made on. Profiles, channels, documents and
  skills are their own modules (`Data.Profiles`, `Data.Channels`,
  `Data.Documents`, `Data.Skills`).
  """

  import Ecto.Query, warn: false

  alias Data.Customers.{Customer, CustomerNote, CustomerTeam}
  alias Data.Repo

  @preload [:user, customer_teams: :team, profiles: [profile_members: [user: :person]]]

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "A customer of the organisation, with teams, profiles and owners; `nil` for a malformed or foreign id."
  @spec get(binary(), binary()) :: Customer.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Customer
        |> Repo.get_by(id: uuid, organisation_id: organisation_id)
        |> Repo.preload(@preload)
        |> fill()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The customer an account signs in as (`customers.user_id`), or `nil`."
  @spec get_by_user(binary()) :: Customer.t() | nil
  def get_by_user(user_id), do: Customer |> Repo.get_by(user_id: user_id) |> fill()

  @doc """
  An organisation's customers by name. Options: `team_ids` (served by any of
  these; `:unassigned` adds the customers in no team), `status`, `q` (name or
  email), `include_archived`.
  """
  @spec list(binary(), keyword()) :: [Customer.t()]
  def list(organisation_id, opts \\ []) do
    from(c in Customer,
      where: c.organisation_id == ^organisation_id,
      order_by: [asc: c.display_name],
      preload: ^@preload
    )
    |> teams(Keyword.get(opts, :team_ids), Keyword.get(opts, :unassigned, false))
    |> status(Keyword.get(opts, :status))
    |> search(Keyword.get(opts, :q))
    |> archived(Keyword.get(opts, :include_archived, false))
    |> Repo.all()
    |> Enum.map(&fill/1)
  end

  defp teams(query, nil, _unassigned), do: query

  defp teams(query, team_ids, unassigned?) do
    served = from(ct in CustomerTeam, where: ct.team_id in ^team_ids, select: ct.customer_id)
    any = from(ct in CustomerTeam, select: ct.customer_id)

    if unassigned?,
      do: where(query, [c], c.id in subquery(served) or c.id not in subquery(any)),
      else: where(query, [c], c.id in subquery(served))
  end

  defp status(query, nil), do: query
  defp status(query, status), do: where(query, [c], c.status == ^status)

  defp search(query, nil), do: query
  defp search(query, ""), do: query

  defp search(query, q) do
    like = "%" <> String.replace(q, ~r/[%_\\]/, "") <> "%"
    where(query, [c], ilike(c.display_name, ^like) or ilike(c.email, ^like))
  end

  defp archived(query, true), do: query
  defp archived(query, false), do: where(query, [c], is_nil(c.archived_at))

  @doc "The virtual `team_ids` from the loaded `customer_teams`; loads them when they are not."
  @spec fill(Customer.t() | nil) :: Customer.t() | nil
  def fill(nil), do: nil

  def fill(%Customer{} = customer) do
    customer = Repo.preload(customer, :customer_teams)
    %{customer | team_ids: Enum.map(customer.customer_teams, & &1.team_id)}
  end

  @doc "The customer again, with every association fresh."
  @spec reload(Customer.t()) :: Customer.t()
  def reload(%Customer{} = customer), do: get(customer.organisation_id, customer.id)

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, customer} <- %Customer{} |> Customer.changeset(attrs) |> Repo.insert() do
      {:ok, customer |> Repo.preload(@preload) |> fill()}
    end
  end

  @spec update(Customer.t(), map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def update(%Customer{} = customer, attrs),
    do: customer |> Customer.changeset(attrs) |> Repo.update()

  @spec change_status(Customer.t(), atom(), Date.t()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def change_status(%Customer{} = customer, status, %Date{} = today),
    do: customer |> Customer.status_changeset(status, today) |> Repo.update()

  @doc "The accepted invitation: the login, and `active` if the customer was only invited."
  @spec attach_login(Customer.t(), binary(), Date.t()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def attach_login(%Customer{} = customer, user_id, %Date{} = today) do
    changeset = Customer.login_changeset(customer, user_id)

    changeset =
      if customer.status == :invited,
        do: Customer.status_changeset(changeset, :active, today),
        else: changeset

    Repo.update(changeset)
  end

  @spec archive(Customer.t(), DateTime.t()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Customer{} = customer, %DateTime{} = at),
    do: customer |> Ecto.Changeset.change(archived_at: at) |> Repo.update()

  # ── Teams ───────────────────────────────────────────────────────────────────

  @spec assign_team(Customer.t(), binary(), Date.t()) ::
          {:ok, CustomerTeam.t()} | {:error, Ecto.Changeset.t()}
  def assign_team(%Customer{} = customer, team_id, %Date{} = since) do
    %CustomerTeam{}
    |> CustomerTeam.changeset(%{customer_id: customer.id, team_id: team_id, since_on: since})
    |> Repo.insert()
  end

  @spec get_team_link(Customer.t(), binary()) :: CustomerTeam.t() | nil
  def get_team_link(%Customer{} = customer, team_id) when is_binary(team_id) do
    case Ecto.UUID.cast(team_id) do
      {:ok, uuid} -> Repo.get_by(CustomerTeam, customer_id: customer.id, team_id: uuid)
      :error -> nil
    end
  end

  def get_team_link(_customer, _team_id), do: nil

  @spec remove_team(CustomerTeam.t()) :: {:ok, CustomerTeam.t()} | {:error, Ecto.Changeset.t()}
  def remove_team(%CustomerTeam{} = link), do: Repo.delete(link)

  # ── Notes ───────────────────────────────────────────────────────────────────

  @doc "A customer's live notes, oldest first, with their authors."
  @spec list_notes(binary()) :: [CustomerNote.t()]
  def list_notes(customer_id) do
    from(n in CustomerNote,
      where: n.customer_id == ^customer_id and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at],
      preload: [author_user: :person]
    )
    |> Repo.all()
  end

  @doc "A live note by id, with its customer (so the caller can ask who may see it)."
  @spec get_note(binary()) :: CustomerNote.t() | nil
  def get_note(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        from(n in CustomerNote,
          where: n.id == ^uuid and is_nil(n.deleted_at),
          preload: [author_user: :person, customer: [customer_teams: []]]
        )
        |> Repo.one()
        |> case do
          nil -> nil
          note -> %{note | customer: fill(note.customer)}
        end

      :error ->
        nil
    end
  end

  def get_note(_id), do: nil

  @spec create_note(map()) :: {:ok, CustomerNote.t()} | {:error, Ecto.Changeset.t()}
  def create_note(attrs) do
    with {:ok, note} <- %CustomerNote{} |> CustomerNote.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(note, author_user: :person)}
    end
  end

  @spec update_note(CustomerNote.t(), map(), DateTime.t()) ::
          {:ok, CustomerNote.t()} | {:error, Ecto.Changeset.t()}
  def update_note(%CustomerNote{} = note, attrs, %DateTime{} = at) do
    note
    |> CustomerNote.changeset(Map.take(stringify(attrs), ["body_md"]))
    |> Ecto.Changeset.put_change(:edited_at, at)
    |> Repo.update()
  end

  @spec delete_note(CustomerNote.t(), DateTime.t()) ::
          {:ok, CustomerNote.t()} | {:error, Ecto.Changeset.t()}
  def delete_note(%CustomerNote{} = note, %DateTime{} = at),
    do: note |> Ecto.Changeset.change(deleted_at: at) |> Repo.update()

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
