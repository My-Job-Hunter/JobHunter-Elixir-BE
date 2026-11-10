defmodule Mix.Tasks.Jh.SeedReference do
  @shortdoc "Loads the reference lists (every environment, test included)"

  @moduledoc """
  The reference lists (PLAN §17): platforms, notification kinds and groups,
  engine stage kinds.

      mix jh.seed_reference
      mix jh.seed_reference --only platforms

  **It runs in every environment, test included**, which is what makes it
  different from the other seeds: reference data is closer to the schema than
  to content, and nothing asserts that a list is empty. The umbrella's `test`
  alias runs it before the suite.

  **Empty in P0**: it prints what it will load and loads nothing. Idempotent by
  key once it has groups. `Data.Seeds.plan(:reference)` lists them and why each
  sits where it does.
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
