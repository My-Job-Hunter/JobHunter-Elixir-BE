defmodule Mix.Tasks.Aq.Vocabulary do
  @shortdoc "Writes apps/data/priv/vocabulary.json from Data.Vocabulary"

  @moduledoc """
  Exports the domain strings the frontend shares (PLAN §20: change both or
  neither) to `apps/data/priv/vocabulary.json`: pretty, keys sorted, each
  list in its order.

      mix aq.vocabulary

  Run it after editing `Data.Vocabulary`; `Data.VocabularyTest` fails until
  you do. It needs no database and starts nothing.
  """

  use Mix.Task

  alias Data.Vocabulary

  @requirements ["compile"]

  @impl Mix.Task
  def run(_args) do
    path = Vocabulary.json_path()
    json = Vocabulary.to_json()

    if File.read(path) == {:ok, json} do
      Mix.shell().info("#{Path.relative_to_cwd(path)} is up to date.")
    else
      File.write!(path, json)
      Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}.")
    end
  end
end
