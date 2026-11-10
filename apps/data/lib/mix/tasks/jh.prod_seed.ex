defmodule Mix.Tasks.Jh.ProdSeed do
  @shortdoc "Loads the production seed: what Job Hunter holds before anyone arrives"

  @moduledoc """
  The production seed (PLAN §17): the reference lists, then the skills
  vocabulary, the two default pipelines and the default settings. No accounts,
  no customers, no jobs: those come through the front door.

      mix jh.prod_seed
      mix jh.prod_seed --only pipelines
      mix ecto.reset.clean          # drop, create, migrate, then this

  Idempotent by key (the skills by slug), so re-running is safe. On a clean
  database the skills group finds no organisation and loads nothing;
  `mix jh.bootstrap` loads it for the organisation it makes. `Data.Seeds.plan(:prod)` lists
  the groups and why each sits where it does.
  """

  use Mix.Task

  alias Data.Seeds

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :string])

    case Seeds.quietly(fn -> Seeds.run(:prod, Keyword.take(opts, [:only])) end) do
      {:ok, results} -> Mix.shell().info("Production seed: " <> Seeds.summary(:prod, results))
      {:error, why} -> Mix.raise(why)
    end
  end
end
