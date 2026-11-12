defmodule Mix.Tasks.Aq.SeedReference do
  @shortdoc "Loads the reference lists (every environment, test included)"

  @moduledoc """
  The reference lists (PLAN §17): platforms, notification kinds and groups,
  engine stage kinds.

      mix aq.seed_reference
      mix aq.seed_reference --only notifications

  **It runs in every environment, test included**, which is what makes it
  different from the other seeds: reference data is closer to the schema than
  to content, and nothing asserts that a list is empty. The umbrella's `test`
  alias runs it before the suite.

  It holds the notification groups and kinds (P2), idempotent by key, and
  each site's selector document as version 1 where it has none (P5).
  `Data.Seeds.plan(:reference)` lists the groups and why each sits where it
  does.
  """

  use Mix.Task

  alias Data.Seeds

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :string])

    case Seeds.quietly(fn -> Seeds.run(:reference, Keyword.take(opts, [:only])) end) do
      {:ok, results} -> Mix.shell().info("Reference seed: " <> Seeds.summary(:reference, results))
      {:error, why} -> Mix.raise(why)
    end
  end
end
