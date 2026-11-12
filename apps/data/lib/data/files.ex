defmodule Data.Files do
  @moduledoc """
  Stored files (`media`, AQ-01 §4.1): a row reserved before the bytes arrive,
  marked uploaded once they have. Storage only; the allowlist, the caps and
  the sniffing are `Core.Media`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Files.Media
  alias Data.Repo

  @doc "Reserves a row for bytes that are about to arrive."
  @spec create(map()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Media{} |> Media.changeset(attrs) |> Repo.insert()

  @doc "A file by id, whoever owns it; `nil` for a malformed id."
  @spec get(binary()) :: Media.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Media, uuid)
      :error -> nil
    end
  end

  def get(_id), do: nil

  @doc "A file the caller uploaded, by id; somebody else's is `nil`, as if it were not there."
  @spec get_own(binary(), binary()) :: Media.t() | nil
  def get_own(user_id, id) do
    case get(id) do
      %Media{owner_user_id: ^user_id} = media -> media
      _other -> nil
    end
  end

  @doc "The bytes arrived: their digest and what the store measured."
  @spec mark_stored(Media.t(), map()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def mark_stored(%Media{} = media, attrs) do
    media |> Ecto.Changeset.cast(attrs, [:sha256, :byte_count]) |> Repo.update()
  end

  @doc "The upload is complete."
  @spec mark_uploaded(Media.t(), map(), DateTime.t()) ::
          {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def mark_uploaded(%Media{} = media, attrs, %DateTime{} = now) do
    media
    |> Ecto.Changeset.cast(attrs, [:width_px, :height_px, :page_count])
    |> Ecto.Changeset.put_change(:uploaded_at, now)
    |> Repo.update()
  end

  @doc "Rows reserved before `cutoff` whose bytes never arrived. Unscoped, for the sweep."
  @spec list_unconfirmed_for_system(DateTime.t()) :: [Media.t()]
  def list_unconfirmed_for_system(%DateTime{} = cutoff) do
    from(m in Media, where: is_nil(m.uploaded_at) and m.inserted_at < ^cutoff) |> Repo.all()
  end

  @doc "Removes an abandoned row. Unscoped, for the sweep."
  @spec delete_for_system(Media.t()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def delete_for_system(%Media{} = media), do: Repo.delete(media)
end
