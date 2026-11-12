defmodule Mix.Tasks.Aq.ExtConfig do
  @shortdoc "Publishes a new version of each selector document whose file changed"

  @moduledoc """
  The extension's selector documents (AQ-05 §6.4, QP5-21): a DOM change on
  LinkedIn or Upwork is a config release, not a store release.

      mix aq.ext_config

  Each site's file in `apps/core/priv/extension/<site>.json` is validated
  against contract 1 (`Core.Extension.Configs.validate/1`) and published as
  the site's next version when its SHA-256 is not the live one's. A file
  off the contract publishes nothing and the task fails, naming every
  problem; an unchanged file is kept. `GET /ext/v1/config` serves the new
  version at once, and the extension's `If-None-Match` sees it change.

  It lives in `core` because the contract does; the reference seed
  publishes version 1 where a site has none.
  """

  use Mix.Task

  alias Core.Clock
  alias Core.Extension.Configs
  alias Data.Scope

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    results = Configs.publish_files(Scope.system(), Configs.dir(), Clock.now())

    for {site, result} <- results, do: Mix.shell().info(line(site, result))

    if Enum.any?(results, &match?({_site, {:invalid, _problems}}, &1)),
      do: Mix.raise("Nothing was published for a file off the contract.")
  end

  defp line(site, {:published, version}), do: "#{site}: published as version #{version}."
  defp line(site, {:unchanged, version}), do: "#{site}: unchanged, version #{version} is live."
  defp line(site, :missing), do: "#{site}: no file."

  defp line(site, {:published_before, version}),
    do: "#{site}: this is version #{version}'s text; change the file to publish it again."

  defp line(site, {:invalid, problems}),
    do: "#{site}: off the contract —\n  " <> Enum.join(problems, "\n  ")
end
