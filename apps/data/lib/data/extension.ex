defmodule Data.Extension do
  @moduledoc """
  The extension's reference data and health (AQ-05 §5.2): the selector
  documents' versions (`extension_configs`) and the misses
  (`extension_misses`). Storage only: what a valid document is, who reads
  the health and when a miss is reported is `Core.Extension`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Extension.{Config, Miss}
  alias Data.Jobs.{Job, Snapshot}
  alias Data.Repo

  # ── Configs ─────────────────────────────────────────────────────────────────

  @doc "The live version of a site's document — the highest — or `nil`."
  @spec live_config(atom() | String.t()) :: Config.t() | nil
  def live_config(site) do
    from(c in Config, where: c.site == ^site(site), order_by: [desc: c.version], limit: 1)
    |> Repo.one()
  end

  @doc """
  Every published version, newest first: one site's by version with
  `site`, every site's by when it was published without.
  """
  @spec configs(atom() | String.t() | nil) :: [Config.t()]
  def configs(site \\ nil)

  def configs(nil),
    do:
      Repo.all(from(c in Config, order_by: [desc: c.published_at, desc: c.version, asc: c.site]))

  def configs(site),
    do: Repo.all(from(c in Config, where: c.site == ^site(site), order_by: [desc: c.version]))

  @doc """
  Publishes `body` as the site's next version, unless it is the live one's
  text already. Answers `{:ok, {:published, config}}`, `{:ok, {:unchanged,
  live}}`, or `{:error, {:published_before, version}}` for the text of an
  older version (the unique `(site, sha256)`: an older text is never live
  again under a new number; change the file to publish it).
  """
  @spec publish(atom() | String.t(), String.t(), DateTime.t()) ::
          {:ok, {:published | :unchanged, Config.t()}}
          | {:error, {:published_before, pos_integer()} | Ecto.Changeset.t()}
  def publish(site, body, %DateTime{} = at) when is_binary(body) do
    site = site(site)
    sha = Config.digest(body)

    case Repo.get_by(Config, site: site, sha256: sha) do
      nil -> insert(site, body, at)
      %Config{} = same -> unchanged_or_older(same, live_config(site))
    end
  end

  defp unchanged_or_older(%Config{id: id} = live, %Config{id: id}), do: {:ok, {:unchanged, live}}
  defp unchanged_or_older(older, _live), do: {:error, {:published_before, older.version}}

  defp insert(site, body, at) do
    version =
      from(c in Config, where: c.site == ^site, select: max(c.version)) |> Repo.one() || 0

    attrs = %{site: site, version: version + 1, body: body, published_at: at}

    with {:ok, config} <- %Config{} |> Config.changeset(attrs) |> Repo.insert(),
         do: {:ok, {:published, config}}
  end

  # The enum's own atoms, so a site is never an atom the VM has not loaded.
  defp site(site) when is_atom(site), do: site

  defp site(site) when is_binary(site),
    do: Enum.find(Ecto.Enum.values(Config, :site), &(Atom.to_string(&1) == site))

  # ── Misses ──────────────────────────────────────────────────────────────────

  @doc """
  Adds a report's misses to their days (`rows`: maps of `Data.Extension.Miss`'s
  columns but `id`, `count` the number seen): a row met again adds to its
  `count` and moves `last_seen_at`. One statement per row, in the caller's
  transaction. Answers how many rows were written.
  """
  @spec add_misses([map()]) :: {:ok, non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def add_misses(rows) do
    Enum.reduce_while(rows, {:ok, 0}, fn attrs, {:ok, n} ->
      changeset = Miss.changeset(%Miss{}, attrs)

      if changeset.valid? do
        {:ok, _miss} =
          Repo.insert(changeset,
            on_conflict:
              from(m in Miss,
                update: [
                  inc: [count: ^attrs.count],
                  set: [last_seen_at: ^attrs.last_seen_at, page_kind: ^attrs.page_kind]
                ]
              ),
            conflict_target: [
              :organisation_id,
              :site,
              :selector_key,
              :config_version,
              :extension_version,
              :seen_on
            ]
          )

        {:cont, {:ok, n + 1}}
      else
        {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  The organisation's misses seen from `since_on` on, summed over the days:
  `%{site, selector_key, page_kind, config_version, extension_version, count,
  first_seen_at, last_seen_at}`, the most recent first.
  """
  @spec misses_since(binary(), Date.t()) :: [map()]
  def misses_since(organisation_id, %Date{} = since_on) do
    from(m in Miss,
      where: m.organisation_id == ^organisation_id and m.seen_on >= ^since_on,
      group_by: [m.site, m.selector_key, m.page_kind, m.config_version, m.extension_version],
      order_by: [desc: max(m.last_seen_at), asc: m.selector_key],
      select: %{
        site: m.site,
        selector_key: m.selector_key,
        page_kind: m.page_kind,
        config_version: m.config_version,
        extension_version: m.extension_version,
        count: type(sum(m.count), :integer),
        first_seen_at: min(m.first_seen_at),
        last_seen_at: max(m.last_seen_at)
      }
    )
    |> Repo.all()
  end

  @doc """
  Deletes every organisation's misses last seen before `before` (the hourly
  sweep's 30 days). Unscoped, and named for it. Answers how many went.
  """
  @spec delete_misses_for_system(DateTime.t()) :: non_neg_integer()
  def delete_misses_for_system(%DateTime{} = before) do
    {n, _rows} = Repo.delete_all(from(m in Miss, where: m.last_seen_at < ^before))
    n
  end

  @doc "When the extension last captured a job of `source` in the organisation, or `nil`."
  @spec last_capture_at(binary(), atom()) :: DateTime.t() | nil
  def last_capture_at(organisation_id, source) do
    from(s in Snapshot,
      join: j in Job,
      on: j.id == s.job_id,
      where:
        j.organisation_id == ^organisation_id and j.source == ^source and
          s.origin == :extension,
      select: max(s.captured_at)
    )
    |> Repo.one()
  end
end
