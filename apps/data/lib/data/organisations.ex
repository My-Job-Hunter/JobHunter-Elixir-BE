defmodule Data.Organisations do
  @moduledoc """
  The organisation, its settings and its admins (JH-01 §4.2). Storage only;
  the guards (the last admin) are `Core.Organisation`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Organisations.{OrgAdmin, Organisation, OrganisationSettings}
  alias Data.Repo

  # ── The organisation ────────────────────────────────────────────────────────

  @spec get(binary()) :: Organisation.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Organisation, uuid)
      :error -> nil
    end
  end

  def get(_id), do: nil

  @spec get_by_slug(String.t()) :: Organisation.t() | nil
  def get_by_slug(slug) when is_binary(slug), do: Repo.get_by(Organisation, slug: slug)

  @doc """
  The one organisation (PLAN Q1): the oldest row. What a scope falls back to
  for an account with no role yet, and what `mix jh.bootstrap` checks before
  making one.
  """
  @spec the_one() :: Organisation.t() | nil
  def the_one, do: Repo.one(from(o in Organisation, order_by: [asc: o.inserted_at], limit: 1))

  @spec create(map()) :: {:ok, Organisation.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Organisation{} |> Organisation.changeset(attrs) |> Repo.insert()

  @spec update(Organisation.t(), map()) :: {:ok, Organisation.t()} | {:error, Ecto.Changeset.t()}
  def update(%Organisation{} = org, attrs),
    do: org |> Organisation.changeset(attrs) |> Repo.update()

  # ── Settings ────────────────────────────────────────────────────────────────

  @doc "The row, or the code defaults when there is none."
  @spec get_settings(binary()) :: OrganisationSettings.t()
  def get_settings(organisation_id) do
    Repo.get(OrganisationSettings, organisation_id) ||
      OrganisationSettings.defaults(organisation_id)
  end

  @doc "Writes the settings, creating the row on first write."
  @spec put_settings(binary(), map()) ::
          {:ok, OrganisationSettings.t()} | {:error, Ecto.Changeset.t()}
  def put_settings(organisation_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Repo.get(OrganisationSettings, organisation_id) do
      nil ->
        %OrganisationSettings{}
        |> OrganisationSettings.changeset(Map.put(attrs, "organisation_id", organisation_id))
        |> Repo.insert()

      row ->
        row |> OrganisationSettings.changeset(attrs) |> Repo.update()
    end
  end

  # ── Admins ──────────────────────────────────────────────────────────────────

  @doc "The admins of an organisation, oldest grant first, with their users and persons."
  @spec list_admins(binary()) :: [OrgAdmin.t()]
  def list_admins(organisation_id) do
    from(a in OrgAdmin,
      where: a.organisation_id == ^organisation_id,
      order_by: [asc: a.granted_at],
      preload: [user: :person]
    )
    |> Repo.all()
  end

  @spec get_admin(binary(), binary()) :: OrgAdmin.t() | nil
  def get_admin(organisation_id, user_id) do
    Repo.get_by(OrgAdmin, organisation_id: organisation_id, user_id: user_id)
  end

  @doc "The organisation ids this user administers."
  @spec admin_of(binary()) :: [binary()]
  def admin_of(user_id) do
    Repo.all(from(a in OrgAdmin, where: a.user_id == ^user_id, select: a.organisation_id))
  end

  @spec count_admins(binary()) :: non_neg_integer()
  def count_admins(organisation_id) do
    Repo.aggregate(from(a in OrgAdmin, where: a.organisation_id == ^organisation_id), :count)
  end

  @spec grant_admin(map()) :: {:ok, OrgAdmin.t()} | {:error, Ecto.Changeset.t()}
  def grant_admin(attrs), do: %OrgAdmin{} |> OrgAdmin.changeset(attrs) |> Repo.insert()

  @spec revoke_admin(OrgAdmin.t()) :: {:ok, OrgAdmin.t()} | {:error, Ecto.Changeset.t()}
  def revoke_admin(%OrgAdmin{} = admin), do: Repo.delete(admin)
end
