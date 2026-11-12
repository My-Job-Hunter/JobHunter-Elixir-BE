defmodule Data.LeadNotes do
  @moduledoc """
  A lead's notes (AQ-04B §5.1, QP4b-13). Storage only: who adds, edits or
  deletes one is `Core.Access.Leads`'s, the ledger row `Core.Leads.Notes`'.
  """

  import Ecto.Query, warn: false

  alias Data.Leads.Note
  alias Data.Repo

  @person [person: :photo]

  @doc "A lead's notes, newest first, with their authors."
  @spec list(binary()) :: [Note.t()]
  def list(lead_id) do
    from(n in Note,
      where: n.lead_id == ^lead_id,
      order_by: [desc: n.inserted_at, desc: n.id],
      preload: [author_user: ^@person]
    )
    |> Repo.all()
  end

  @doc "How many notes each lead has: `%{lead_id => n}`."
  @spec counts([binary()]) :: %{binary() => non_neg_integer()}
  def counts([]), do: %{}

  def counts(lead_ids) do
    from(n in Note,
      where: n.lead_id in ^lead_ids,
      group_by: n.lead_id,
      select: {n.lead_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "A note of the organisation; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Note.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Note
        |> Repo.get_by(id: uuid, organisation_id: organisation_id)
        |> Repo.preload(author_user: @person)

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @spec create(map()) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, note} <- %Note{} |> Note.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, Repo.preload(note, author_user: @person)}
  end

  @spec update(Note.t(), map()) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def update(%Note{} = note, attrs) do
    with {:ok, updated} <- note |> Note.changeset(attrs) |> Repo.update(),
         do: {:ok, Repo.preload(updated, [author_user: @person], force: true)}
  end

  @spec delete(Note.t()) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Note{} = note), do: Repo.delete(note)
end
