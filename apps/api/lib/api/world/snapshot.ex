defmodule Api.World.Snapshot do
  @moduledoc """
  The P3 world as `mix aq.world` replays it (AQ-03B §8):
  `apps/api/priv/world/p3-snapshot.json`, a dump of the old dev database's
  rows by table (secrets left out), and the files in `priv/world/files`.
  Read only; every id in it is the old database's, mapped to the new one as
  the run makes each row.
  """

  @doc "The snapshot, by table name: P3's by default, or another of `priv/world` (`p4a-snapshot.json`)."
  @spec load(String.t()) :: map()
  def load(name \\ "p3-snapshot.json"), do: path(name) |> File.read!() |> Jason.decode!()

  @doc "A file of the world, as bytes."
  @spec file!(String.t()) :: binary()
  def file!(name), do: name |> then(&path("files/" <> &1)) |> File.read!()

  @doc "The rows of `table`, oldest first."
  @spec rows(map(), String.t()) :: [map()]
  def rows(snap, table) do
    snap
    |> Map.get(table, [])
    |> Enum.sort_by(&{&1["inserted_at"] || "", &1["id"] || ""})
  end

  @doc "The row of `table` whose `id` is `id`."
  @spec row!(map(), String.t(), binary()) :: map()
  def row!(snap, table, id),
    do: Enum.find(snap[table], &(&1["id"] == id)) || raise("no #{table} #{id}")

  @doc "A user's email, by their old id."
  @spec email(map(), binary()) :: String.t()
  def email(snap, user_id), do: row!(snap, "users", user_id)["email"]

  @doc "A user's display name, by their old id."
  @spec name(map(), binary()) :: String.t()
  def name(snap, user_id) do
    person = row!(snap, "persons", row!(snap, "users", user_id)["person_id"])
    person["display_name"]
  end

  @doc "The old user id behind an email."
  @spec user_by_email(map(), String.t()) :: binary()
  def user_by_email(snap, email), do: Enum.find(snap["users"], &(&1["email"] == email))["id"]

  @doc "`row` without the keys a write never sends, and without nils."
  @spec writable(map(), [String.t()]) :: map()
  def writable(row, drop) do
    row
    |> Map.drop(["id", "inserted_at", "updated_at", "organisation_id" | drop])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp path(name), do: Application.app_dir(:api, Path.join("priv/world", name))
end
