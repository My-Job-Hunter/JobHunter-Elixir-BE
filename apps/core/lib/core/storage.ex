defmodule Core.Storage do
  @moduledoc """
  Where uploaded bytes live (AutoCare's seam, trimmed). **One behaviour, one
  adapter today** (`Core.Storage.Local`, a folder on this box), chosen in
  config so S3 is a config change and not a frontend release — which is the
  whole reason the three-step upload exists.

  > **Uploaded bytes are never served by a static plug.** They live outside
  > `priv/static`, and every read goes through `ApiShared.MediaController`,
  > which resolves the row and checks the signed link first.
  """

  alias Core.Storage.Local

  @type upload_target :: %{url: String.t(), method: String.t(), headers: map()}

  @callback put(key :: String.t(), body :: binary()) :: :ok | {:error, term()}
  @callback fetch(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback size(key :: String.t()) :: non_neg_integer() | nil
  @doc "Removes bytes. Missing is `:ok`."
  @callback delete(key :: String.t()) :: :ok
  @callback upload_target(key :: String.t(), media_id :: String.t(), path :: String.t()) ::
              {:ok, upload_target()}

  @extensions %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/webp" => ".webp",
    "application/pdf" => ".pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ".docx",
    "text/plain" => ".txt",
    "text/markdown" => ".md"
  }

  @doc """
  A storage key for a new upload: **generated, never derived from the
  filename**. The extension comes from the validated type, and the
  two-character prefix is a directory shard.
  """
  @spec key_for(String.t()) :: String.t()
  def key_for(content_type) do
    id = Ecto.UUID.generate()
    "#{String.slice(id, 0, 2)}/#{id}#{Map.get(@extensions, content_type, ".bin")}"
  end

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, body), do: adapter().put(key, body)

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(key), do: adapter().fetch(key)

  @spec size(String.t()) :: non_neg_integer() | nil
  def size(key), do: adapter().size(key)

  @spec delete(String.t()) :: :ok
  def delete(key), do: adapter().delete(key)

  @spec upload_target(String.t(), String.t(), String.t()) :: {:ok, upload_target()}
  def upload_target(key, media_id, path), do: adapter().upload_target(key, media_id, path)

  @doc "Which adapter is in play."
  @spec adapter() :: module()
  def adapter, do: :core |> Application.get_env(:storage, []) |> Keyword.get(:adapter, Local)

  @doc """
  The largest upload accepted for a kind of file, in bytes (QP1-3: 5 MB for
  a photo, 10 MB for a document or attachment). Read here by both halves of
  the upload, so the size the row is validated against and the size the
  bytes are refused at cannot drift.
  """
  @spec max_bytes(atom()) :: pos_integer()
  def max_bytes(kind) do
    caps = :core |> Application.get_env(:storage, []) |> Keyword.get(:max_bytes, [])
    Keyword.get(caps, kind, Keyword.get(caps, :document, 10_000_000))
  end

  @doc "Creates the local storage root at boot, or refuses to start."
  @spec prepare_root!() :: :ok
  def prepare_root! do
    if adapter() == Local do
      case File.mkdir_p(Local.root()) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "UPLOADS_ROOT cannot be created (#{inspect(reason)}): #{Local.root()}"
      end
    else
      :ok
    end
  end
end
