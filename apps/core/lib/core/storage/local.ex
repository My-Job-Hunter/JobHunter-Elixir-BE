defmodule Core.Storage.Local do
  @moduledoc """
  Bytes in a folder on this box. A real adapter, correct for a single node
  with a mounted volume. **Every path is resolved and checked against the
  root** on the expanded absolute path, not the string: `../` should never
  reach here, and it is refused anyway.
  """

  @behaviour Core.Storage

  require Logger

  @impl Core.Storage
  def put(key, body) when is_binary(body) do
    with {:ok, path} <- resolve(key),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body) do
      # Somebody's CV on a box that may run other things: this process and nothing else.
      _ignored = File.chmod(path, 0o600)
      :ok
    end
  end

  @impl Core.Storage
  def fetch(key) do
    with {:ok, path} <- resolve(key), do: File.read(path)
  end

  @impl Core.Storage
  def size(key) do
    with {:ok, path} <- resolve(key),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      size
    else
      _missing -> nil
    end
  end

  @impl Core.Storage
  def delete(key) do
    case resolve(key) do
      {:ok, path} ->
        _ignored = File.rm(path)
        :ok

      {:error, reason} ->
        Logger.warning("refused to delete outside the storage root: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Our own endpoint: nothing to presign, and the same shape S3 would answer."
  @impl Core.Storage
  def upload_target(_key, media_id, path) do
    {:ok, %{url: "#{path}/#{media_id}/blob", method: "PUT", headers: %{}}}
  end

  @doc "Where this adapter writes. Read at call time, so tests can point it elsewhere."
  @spec root() :: String.t()
  def root, do: :core |> Application.get_env(:storage, []) |> Keyword.get(:root, "priv/uploads")

  defp resolve("/" <> _absolute), do: {:error, :outside_root}

  defp resolve(key) when is_binary(key) do
    root = Path.expand(root())
    path = Path.expand(Path.join(root, key))

    if String.starts_with?(path, root <> "/"), do: {:ok, path}, else: {:error, :outside_root}
  end

  defp resolve(_key), do: {:error, :invalid_key}
end
