defmodule Data.ShareLinks do
  @moduledoc """
  Share links' rows (AQ-03B §3.3, §4). Storage only: who may make, list,
  revoke and open one, and what an open shows, are `Core.ShareLinks`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Audit.AuditEvent
  alias Data.Repo
  alias Data.ShareLinks.ShareLink

  @person [person: :photo]

  @doc "A link of the organisation by id, with its maker; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: ShareLink.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        ShareLink
        |> Repo.get_by(id: uuid, organisation_id: organisation_id)
        |> preload_maker()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The link whose token hashes to `sha256`, with its maker, or `nil`."
  @spec get_by_hash(binary()) :: ShareLink.t() | nil
  def get_by_hash(sha256) when is_binary(sha256),
    do: ShareLink |> Repo.get_by(token_sha256: sha256) |> preload_maker()

  @doc "An item's links, newest first, with their makers: `{:task | :job | :lead, id}`."
  @spec list_for({:task | :job | :lead, binary()}) :: [ShareLink.t()]
  def list_for({kind, id}) when kind in [:task, :job, :lead] do
    field = :"#{kind}_id"

    from(l in ShareLink,
      where: field(l, ^field) == ^id,
      order_by: [desc: l.inserted_at, desc: l.id],
      preload: [created_by_user: ^@person]
    )
    |> Repo.all()
  end

  @spec create(map()) :: {:ok, ShareLink.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, link} <- %ShareLink{} |> ShareLink.changeset(attrs) |> Repo.insert(),
         do: {:ok, preload_maker(link)}
  end

  @spec revoke(ShareLink.t(), DateTime.t(), binary() | nil) :: {:ok, ShareLink.t()}
  def revoke(%ShareLink{} = link, %DateTime{} = at, user_id) do
    {:ok, revoked} = link |> ShareLink.revoke_changeset(at, user_id) |> Repo.update()
    {:ok, preload_maker(revoked)}
  end

  @doc """
  Whether `user_id` opened the link since `since`: an audit row
  `share_link_opened` about it by them (the once-a-day rule, AQ-03B §3.3).
  """
  @spec opened_since?(ShareLink.t(), binary(), DateTime.t()) :: boolean()
  def opened_since?(%ShareLink{} = link, user_id, %DateTime{} = since) do
    from(e in AuditEvent,
      where:
        e.organisation_id == ^link.organisation_id and e.subject_kind == "share_links" and
          e.subject_id == ^link.id and e.action == "share_link_opened" and
          e.actor_user_id == ^user_id and e.occurred_at >= ^since
    )
    |> Repo.exists?()
  end

  defp preload_maker(nil), do: nil
  defp preload_maker(link), do: Repo.preload(link, created_by_user: @person)
end
