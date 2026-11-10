defmodule Mix.Tasks.Jh.SeedDemo do
  @shortdoc "Loads the dev-only demo rows (never in test, never in a release)"

  @moduledoc """
  The dev-only rows, after the production seed (`seeds/0` in the umbrella's
  `mix.exs`).

      mix jh.seed_demo

  **The cast is not here.** PLAN §17 makes Dawud, the team leads, the members
  and the customers through the front door, by each phase's run, so the
  product proves it can make them. This group is for the rows no front door
  can make, and it is empty in P0.
  """

  use Mix.Task

  alias Data.Seeds

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :string])

    case Seeds.quietly(fn -> Seeds.run(:demo, Keyword.take(opts, [:only])) end) do
      {:ok, results} -> Mix.shell().info("Demo seed: " <> Seeds.summary(:demo, results))
      {:error, why} -> Mix.raise(why)
    end
  end
end
