defmodule Data.Seeds.ExtensionConfigs do
  @moduledoc """
  The selector documents (AQ-05 §13, QP5-21): reference data, loaded in
  **every environment, test included**. Each site's file in
  `apps/core/priv/extension/<site>.json` is published as **version 1** when
  the site has no version yet, so test, dev and a fresh deployment all have
  one; a site that has one is kept. A changed file becomes a new version
  through `mix aq.ext_config`, which validates it first
  (`Core.Extension.Configs.validate/1`); here only the files' own test
  stands between a bad file and the table, because `data` cannot name `core`.
  """

  alias Data.Extension
  alias Data.Vocabulary

  @doc "Publishes each site's file as v1 where the site has none. Answers `%{inserted, kept}`."
  @spec load(keyword()) :: %{inserted: non_neg_integer(), kept: non_neg_integer()}
  def load(opts \\ []) do
    dir = Keyword.get(opts, :dir, dir())
    now = DateTime.utc_now()

    for site <- Vocabulary.ext_sites(),
        path = Path.join(dir, site <> ".json"),
        File.exists?(path),
        reduce: %{inserted: 0, kept: 0} do
      acc ->
        if Extension.live_config(site) do
          Map.update!(acc, :kept, &(&1 + 1))
        else
          {:ok, {:published, _config}} = Extension.publish(site, File.read!(path), now)
          Map.update!(acc, :inserted, &(&1 + 1))
        end
    end
  end

  @doc """
  Where the files are: `core`'s `priv/extension` as built, else the source
  tree's (`data` is built before `core` can be asked).
  """
  @spec dir() :: Path.t()
  def dir do
    case :code.priv_dir(:core) do
      path when is_list(path) ->
        built = Path.join(List.to_string(path), "extension")
        if File.dir?(built), do: built, else: source_dir()

      {:error, _not_loaded} ->
        source_dir()
    end
  end

  defp source_dir, do: Path.expand("../../../../core/priv/extension", __DIR__)
end
