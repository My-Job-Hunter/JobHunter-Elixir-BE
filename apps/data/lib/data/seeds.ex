defmodule Data.Seeds do
  @moduledoc """
  What gets seeded, and in what order.

  **One place, because several callers have to agree**: the umbrella's
  `mix.exs` (`seeds/0`), the Mix tasks, and later a release, which has no Mix.
  A seed wired into `mix.exs` alone is one that never reaches production; a
  seed wired into both, separately, is two lists that drift.

  ## The groups (PLAN §17)

  | Kind | Task | Runs | Will hold |
  |---|---|---|---|
  | `:reference` | `mix jh.seed_reference` | every environment, **test included** | platforms, notification kinds and groups, engine stage kinds |
  | `:prod` | `mix jh.prod_seed` | a deployment, and every dev database | the reference groups, then the skills vocabulary, the two default pipelines, the default settings |
  | `:demo` | `mix jh.seed_demo` | dev only | rows no front door can make; the cast itself is made through the front door by each phase's run |

  **Every group is empty in P0**: there are no tables for them yet. Each
  phase adds its groups to `plan/1` with the reason it sits where it does, and
  `coming/1` loses the line it delivered.

  ## Why nothing but reference runs in test

  A suite that starts with seeded accounts cannot assert "a fresh account has
  nothing waiting". That is arranged by not calling them: `seeds/0` in the
  umbrella's `mix.exs` drops everything but the reference groups under
  `MIX_ENV=test`. Nothing here checks.
  """

  @type kind :: :reference | :prod | :demo

  @typedoc """
  One seed group. `because` says why it sits where it does: with foreign keys
  between groups, the reason is what stops somebody reordering them into an
  error on a deploy day. `args` is a function of the options, so an entry
  supplies its own arguments rather than the runner guessing them.
  """
  @type entry :: %{
          key: atom(),
          module: module(),
          fun: atom(),
          label: String.t(),
          because: String.t(),
          args: (keyword() -> [any()])
        }

  @kinds [:reference, :prod, :demo]

  @doc "The seed kinds, in the order a fresh dev database runs them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The seeds of one kind, in dependency order.

  `:prod` starts with every `:reference` group, so `mix ecto.reset.clean`
  (drop, create, migrate, `jh.prod_seed`) stands on its own. Groups are
  idempotent by key, so running reference twice on a dev database is harmless.
  """
  @spec plan(kind()) :: [entry()]
  def plan(:reference), do: []

  def plan(:prod) do
    plan(:reference) ++
      [
        %{
          key: :skills,
          module: Data.Seeds.Skills,
          fun: :load,
          label: "the skills vocabulary",
          because:
            "profiles point at skills by id (P1.2, QP1-4); it loads into every organisation that exists, " <>
              "and the bootstrap loads it again for the organisation it makes",
          args: fn _opts -> [[]] end
        }
      ]
  end

  def plan(:demo), do: []

  @doc """
  What each kind will hold, and the phase that brings it. Printed by the
  tasks while a kind is still empty, so running one says what it is for.
  """
  @spec coming(kind()) :: [String.t()]
  def coming(:reference) do
    [
      "the platforms (P1.2, with channels)",
      "the engine stage kinds (P4a, with pipelines)",
      "the notification kinds and groups (P2, with the bell)"
    ]
  end

  # **Not here: the organisation, its settings, the teams' settings.** JH-01
  # §3 makes the organisation through `mix jh.bootstrap` (the front door's
  # first key), and the 1:1 settings tables answer code defaults until a row
  # is written. Seeding them would be a second way to make the one thing the
  # bootstrap exists to make.
  def coming(:prod) do
    [
      "the reference groups, first",
      "the two default pipelines, Employment and Freelance (P4a)"
    ]
  end

  def coming(:demo) do
    ["nothing by design: the cast (PLAN §17) is made through the front door by each phase's run"]
  end

  @doc """
  Runs a kind, or says why it did not.

  ## Options

    * `:only` — run one group by its `key`. An unknown key is an error rather
      than a silent no-op: a typo that quietly seeds nothing is the failure
      this module is written against.
  """
  @spec run(kind(), keyword()) :: {:ok, [{String.t(), any()}]} | {:error, String.t()}
  def run(kind, opts \\ []) when kind in @kinds do
    with {:ok, entries} <- select(plan(kind), Keyword.get(opts, :only)) do
      {:ok, Enum.map(entries, &{&1.label, apply(&1.module, &1.fun, &1.args.(opts))})}
    end
  end

  # **Compared as strings, never `String.to_existing_atom/1`.** The key comes
  # from a command line, and that function raises when the atom has not been
  # loaded yet.
  defp select(entries, nil), do: {:ok, entries}

  defp select(entries, key) do
    wanted = to_string(key)

    case Enum.filter(entries, &(to_string(&1.key) == wanted)) do
      [] -> {:error, "no seed group named #{inspect(key)} — try #{known(entries)}"}
      chosen -> {:ok, chosen}
    end
  end

  defp known([]), do: "none: this kind has no groups yet"
  defp known(entries), do: Enum.map_join(entries, ", ", &inspect(&1.key))

  @doc """
  Runs something with the SQL log turned down.

  A few hundred inserts at `:debug` is a wall of statements that buries the
  one thing somebody ran the task to read. **Module-level, not global** — a
  real warning from the seed itself still gets through.
  """
  @spec quietly((-> result)) :: result when result: any()
  def quietly(work) do
    previous = Logger.get_module_level(Ecto.Adapters.SQL)
    Logger.put_module_level(Ecto.Adapters.SQL, :none)

    try do
      work.()
    after
      restore(previous)
    end
  end

  defp restore([{_module, level}]), do: Logger.put_module_level(Ecto.Adapters.SQL, level)
  defp restore(_none), do: Logger.delete_module_level(Ecto.Adapters.SQL)

  @doc """
  The line a task prints after a run: what loaded, or what is coming.
  """
  @spec summary(kind(), [{String.t(), any()}]) :: String.t()
  def summary(kind, []) do
    "Nothing to load yet for #{kind}. It will hold: " <> Enum.join(coming(kind), "; ") <> "."
  end

  def summary(_kind, results) do
    "Loaded " <>
      Enum.map_join(results, ", ", fn {label, result} -> "#{label} (#{count(result)})" end) <> "."
  end

  defp count(result) when is_map(result), do: result |> Map.values() |> Enum.sum()
  defp count(result) when is_integer(result), do: result
  defp count(_result), do: "done"
end
