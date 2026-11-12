defmodule Data.Invitations do
  @moduledoc """
  The front door's rows (AQ-01 §3, §4.2). Storage only; the lifetimes, the
  states and who may invite whom are `Core.Organisation.Invitations`'s.

  A customer invitation is answered with its customer and the customer's
  `team_ids` filled, because `Core.Access` decides from them who may read
  or revoke it.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Customers.CustomerTeam
  alias Data.Invitations.Invitation
  alias Data.Repo

  @preload [:team, invited_by_user: :person, organisation: [], customer: [:customer_teams]]

  @doc "By code, whatever its state; `nil` for a code of the wrong shape."
  @spec get_by_code(String.t()) :: Invitation.t() | nil
  def get_by_code(code) when is_binary(code) do
    code = code |> String.trim() |> String.upcase()

    if Regex.match?(Invitation.code_shape(), code),
      do: Invitation |> Repo.get_by(code: code) |> load(),
      else: nil
  end

  def get_by_code(_code), do: nil

  @doc "By id within an organisation."
  @spec get(binary(), binary()) :: Invitation.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Invitation |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "One by id, for the job that mails it. Unscoped, and named for it."
  @spec get_for_system(binary()) :: Invitation.t() | nil
  def get_for_system(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Invitation |> Repo.get(uuid) |> load()
      :error -> nil
    end
  end

  @doc """
  An organisation's invitations, newest first. `team_ids` narrows to those
  teams' members and the customers those teams serve (and no admin ones);
  `state: :open` keeps the unaccepted, unrevoked and unexpired at `now`.
  """
  @spec list(binary(), keyword()) :: [Invitation.t()]
  def list(organisation_id, opts \\ []) do
    query =
      from(i in Invitation,
        where: i.organisation_id == ^organisation_id,
        order_by: [desc: i.inserted_at]
      )

    query =
      case Keyword.get(opts, :team_ids) do
        nil ->
          query

        ids ->
          served = from(ct in CustomerTeam, where: ct.team_id in ^ids, select: ct.customer_id)
          where(query, [i], i.team_id in ^ids or i.customer_id in subquery(served))
      end

    query =
      case {Keyword.get(opts, :state), Keyword.get(opts, :now)} do
        {:open, %DateTime{} = now} ->
          where(
            query,
            [i],
            is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^now
          )

        _all ->
          query
      end

    query |> Repo.all() |> Enum.map(&load/1)
  end

  @doc "The open invitation (not accepted, not revoked, any expiry) for a target, or `nil`."
  @spec open_for(binary(), atom(), String.t(), binary() | nil) :: Invitation.t() | nil
  def open_for(organisation_id, kind, email, target_id) do
    base =
      from(i in Invitation,
        where:
          i.organisation_id == ^organisation_id and i.kind == ^kind and i.email == ^email and
            is_nil(i.accepted_at) and is_nil(i.revoked_at)
      )

    case kind do
      :team_member -> where(base, [i], i.team_id == ^target_id)
      :customer -> where(base, [i], i.customer_id == ^target_id)
      :admin -> base
    end
    |> Repo.one()
    |> load()
  end

  @spec create(map()) :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, invitation} <- %Invitation{} |> Invitation.changeset(attrs) |> Repo.insert() do
      {:ok, load(invitation)}
    end
  end

  @spec extend(Invitation.t(), DateTime.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def extend(%Invitation{} = invitation, %DateTime{} = expires_at),
    do: invitation |> Ecto.Changeset.change(expires_at: expires_at) |> Repo.update()

  @spec accept(Invitation.t(), binary(), DateTime.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def accept(%Invitation{} = invitation, user_id, %DateTime{} = at) do
    invitation
    |> Ecto.Changeset.change(accepted_at: at, accepted_by_user_id: user_id)
    |> Repo.update()
  end

  @spec revoke(Invitation.t(), DateTime.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Invitation{} = invitation, %DateTime{} = at),
    do: invitation |> Ecto.Changeset.change(revoked_at: at) |> Repo.update()

  # Everything a screen or a decision needs, with the customer's team ids.
  defp load(nil), do: nil

  defp load(%Invitation{} = invitation) do
    invitation = Repo.preload(invitation, @preload)
    %{invitation | customer: Customers.fill(invitation.customer)}
  end
end
