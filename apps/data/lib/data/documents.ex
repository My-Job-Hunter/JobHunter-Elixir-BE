defmodule Data.Documents do
  @moduledoc """
  A profile's documents and their files (JH-01 §4.3). Storage only. Every
  read answers the document with its profile and the profile's customer
  (with `team_ids`), because `Core.Access` decides from the customer.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Customers.{Document, DocumentMedia}
  alias Data.Repo

  @preload [
    document_media: [:media],
    profile: [:default_document_link, customer: [:customer_teams]]
  ]

  @spec get(binary()) :: Document.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Document |> Repo.get(uuid) |> Repo.preload(@preload) |> fill()
      :error -> nil
    end
  end

  def get(_id), do: nil

  @doc "A profile's live documents, by label then version."
  @spec list(binary(), keyword()) :: [Document.t()]
  def list(profile_id, opts \\ []) do
    query =
      from(d in Document,
        where: d.profile_id == ^profile_id,
        order_by: [asc: d.label, desc: d.version_no],
        preload: ^@preload
      )

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [d], is_nil(d.archived_at))

    query |> Repo.all() |> Enum.map(&fill/1)
  end

  @doc "The highest version a label has reached on a profile, archived included; 0 when none."
  @spec last_version(binary(), String.t()) :: non_neg_integer()
  def last_version(profile_id, label) do
    from(d in Document,
      where: d.profile_id == ^profile_id and d.label == ^label,
      select: max(d.version_no)
    )
    |> Repo.one() || 0
  end

  @spec reload(Document.t()) :: Document.t()
  def reload(%Document{id: id}), do: get(id)

  defp fill(nil), do: nil

  defp fill(%Document{} = document) do
    profile = %{document.profile | customer: Customers.fill(document.profile.customer)}
    %{document | profile: profile}
  end

  @spec create(map()) :: {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Document{} |> Document.changeset(attrs) |> Repo.insert()

  @spec update(Document.t(), map()) :: {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def update(%Document{} = document, attrs),
    do: document |> Document.changeset(attrs) |> Repo.update()

  @spec archive(Document.t(), DateTime.t()) :: {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Document{} = document, %DateTime{} = at),
    do: document |> Ecto.Changeset.change(archived_at: at) |> Repo.update()

  @doc "Attaches the file: the one `document_media` row a document has."
  @spec attach_media(Document.t(), binary()) ::
          {:ok, DocumentMedia.t()} | {:error, Ecto.Changeset.t()}
  def attach_media(%Document{} = document, media_id) do
    %DocumentMedia{}
    |> DocumentMedia.changeset(%{document_id: document.id, media_id: media_id})
    |> Repo.insert()
  end
end
