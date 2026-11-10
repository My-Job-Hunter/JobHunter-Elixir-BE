defmodule Core.ConventionsTest do
  @moduledoc """
  Conventions enforced as tests, because their failure mode is silence.

  Copied from AutoCare's `Core.ConventionsTest` with every rule kept. Dropped,
  because they guard seams Job Hunter does not have: AutoCare's task-query
  seam (`Data.Tasks.scope_query/2`, which excludes series templates from a
  board) and its list of not-yet-converted enum fields (we start with none).

  Added: every dependency lives in `utils`, and every table with `timestamps()`
  carries the `touch_updated_at` trigger.

  Most rules pass vacuously in P0 — there are no schemas yet. They are here so
  the first schema meets them, not the tenth.
  """

  use ExUnit.Case, async: true

  @apps ~w(utils data core notifire api_shared api_team api_client api_ext api)
  # From this file: apps/core/lib/core/ → ../../../..
  @root Path.expand("../../../..", __DIR__)
  @migrations "apps/data/priv/repo/migrations/*.exs"
  @schemas "apps/data/lib/data/**/*.ex"

  defp count(path, pattern), do: path |> File.read!() |> then(&length(Regex.scan(pattern, &1)))

  defp migration_source do
    @root
    |> Path.join(@migrations)
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "the app list here is every app in the umbrella" do
    on_disk =
      @root
      |> Path.join("apps/*/mix.exs")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))

    assert Enum.sort(on_disk) == Enum.sort(@apps),
           "add the new app to @apps above, so every rule here reaches it"
  end

  describe "test files" do
    test "no test is named *_test.exs — it would be silently skipped" do
      # `test_pattern: "*.test.exs"` means a conventionally-named Elixir test
      # file matches nothing, runs zero cases, and reports success.
      offenders =
        Path.wildcard(Path.join(@root, "apps/*/{lib,test}/**/*_test.exs"))
        |> Enum.map(&Path.relative_to(&1, @root))

      assert offenders == [],
             "these files will never run — rename to *.test.exs: #{inspect(offenders)}"
    end

    test "every app has the empty lib/test_helper.exs that test_paths demands" do
      missing =
        Enum.reject(@apps, fn app ->
          File.exists?(Path.join(@root, "apps/#{app}/lib/test_helper.exs"))
        end)

      assert missing == [],
             "test_paths includes lib/, so Mix needs a helper there: #{inspect(missing)}"
    end
  end

  describe "migrations" do
    test "one table per migration" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @migrations)),
            tables = count(path, ~r{create table\(}),
            tables > 1,
            do: "#{Path.basename(path)} creates #{tables}"

      assert offenders == [],
             """
             A migration creating several tables cannot be reviewed, reverted or
             reordered on its own, and half-applies when one of them fails.
             Split them: #{inspect(offenders)}
             """
    end

    # Pre-production, a column is added by **editing the create migration**
    # (PLAN §15.2): nothing is deployed, so a migration is not yet a fact
    # about anybody's database. **This inverts on the first production
    # deploy**, when forward-only becomes the rule and this test is deleted.
    test "no alter table, because nothing is deployed yet" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @migrations)),
            count(path, ~r{alter table\(}) > 0,
            do: Path.basename(path)

      assert offenders == [],
             """
             Fold these into the create migration they alter, then
             `mix ecto.reset` and `MIX_ENV=test mix ecto.reset`: #{inspect(offenders)}
             """
    end

    test "every migration is named verb + subject" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @migrations)),
            name = Path.basename(path, ".exs"),
            not Regex.match?(~r/^\d{14}_(create|add|remove|rename|drop)_[a-z0-9_]+$/, name),
            do: name

      assert offenders == [],
             "name a migration for what it does — create_leads, add_x_to_y: #{inspect(offenders)}"
    end

    # `mix ecto.reset` working from scratch is what makes rewriting them safe.
    test "no migration depends on data already being there" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @migrations)),
            count(path, ~r{^\s*(execute\("(UPDATE|INSERT)|repo\(\)\.(update_all|insert_all))}m) >
              0,
            do: Path.basename(path)

      assert offenders == [],
             "backfills belong in a seed task, not a migration: #{inspect(offenders)}"
    end

    # `updated_at` moves on every update, whoever writes it — but only on a
    # table that carries the trigger, and the function alone attaches to
    # nothing (`create_touch_updated_at_function`).
    test "every table with timestamps() carries the touch_updated_at trigger" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @migrations)),
            count(path, ~r{create table\(}) > 0,
            count(path, ~r{timestamps\(}) > 0,
            count(path, ~r{CREATE TRIGGER touch_updated_at}) == 0,
            do: Path.basename(path)

      assert offenders == [],
             "add `CREATE TRIGGER touch_updated_at BEFORE UPDATE ON <table> " <>
               "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()`: #{inspect(offenders)}"
    end
  end

  describe "schema field names" do
    # **`_at` is a timestamp; `_on` is a calendar date.** `Date.diff/2` and
    # `DateTime.diff/2` take different structs, so a `:date` called
    # `expires_at` is a FunctionClauseError somebody hits at runtime.
    test "a :date field is never named _at" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @schemas)),
            [_line, name] <- Regex.scan(~r/field\(:([a-z_0-9]+), :date[,)]/, File.read!(path)),
            String.ends_with?(name, "_at"),
            do: "#{Path.basename(path)}:#{name}"

      assert offenders == [],
             "a :date is _on or _date; only a timestamp is _at: #{inspect(offenders)}"
    end

    # The mirror of the rule above, and the more dangerous direction: a
    # timestamp named `_on` reads as a date to every caller.
    test "a timestamp field is never named _on or _date" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @schemas)),
            [_line, name] <-
              Regex.scan(~r/field\(:([a-z_0-9]+), :utc_datetime[a-z_]*[,)]/, File.read!(path)),
            String.ends_with?(name, "_on") or String.ends_with?(name, "_date"),
            do: "#{Path.basename(path)}:#{name}"

      assert offenders == [],
             "a timestamp is _at: #{inspect(offenders)}"
    end
  end

  describe "closed sets" do
    # **`validate_inclusion` holds only where a changeset runs.** `Ecto.Enum`
    # checks on cast, load *and* dump; the CHECK constraint beside it is what
    # stops a mix task or a psql session writing something the code cannot
    # read. AutoCare carries a list of fields not yet converted; we start with
    # none, so there is no list.
    test "a closed set is an Ecto.Enum, not validate_inclusion against a ~w() list" do
      offenders =
        for path <- Path.wildcard(Path.join(@root, @schemas)),
            [_line, field] <-
              Regex.scan(~r/validate_inclusion\(:([a-z_0-9]+), @[a-z_]+\)/, File.read!(path)),
            do: "#{Path.basename(path)}:#{field}"

      assert offenders == [],
             "use `field(:x, Ecto.Enum, values: @set)` plus a CHECK constraint: " <>
               inspect(offenders)
    end

    # An `Ecto.Enum` with no constraint behind it is an application-level check
    # wearing a database's clothes.
    test "every Ecto.Enum field has a CHECK constraint naming it" do
      migrations = migration_source()

      offenders =
        for path <- Path.wildcard(Path.join(@root, @schemas)),
            [_line, field] <-
              Regex.scan(~r/field\(:([a-z_0-9]+), (?:\{:array, )?Ecto\.Enum/, File.read!(path)),
            not String.contains?(migrations, ":#{field}_known"),
            do: "#{Path.basename(path)}:#{field}"

      assert offenders == [],
             "add `create(constraint(:table, :<field>_known, check: …))`: #{inspect(offenders)}"
    end
  end

  describe "the error contract" do
    test "no response body uses a success: false envelope" do
      # An envelope restating the HTTP status gives every client two places
      # to check that can disagree, and carries no stable code.
      offenders =
        Path.wildcard(Path.join(@root, "apps/*/lib/**/*.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/success:\s*false/))
        |> Enum.map(&Path.relative_to(&1, @root))

      assert offenders == [],
             "errors are {error: {code, message, details}} — see CONVENTIONS §7: #{inspect(offenders)}"
    end

    test "only the FallbackController and ErrorJSON decide a status code" do
      # A body assembled at a call site is how the contract drifts.
      allowed = ["fallback_controller.ex", "error_json.ex", "error_handler.ex", "scope.ex"]

      offenders =
        Path.wildcard(Path.join(@root, "apps/api*/lib/**/*.ex"))
        |> Enum.reject(&(Path.basename(&1) in allowed))
        |> Enum.filter(
          &(File.read!(&1) =~ ~r/put_status\(:?(not_found|unauthorized|forbidden|unprocessable)/)
        )
        |> Enum.map(&Path.relative_to(&1, @root))

      assert offenders == [],
             "return {:error, reason} and let the fallback shape it: #{inspect(offenders)}"
    end
  end

  describe "layering" do
    test "data never depends on core — the boundary is a compile error" do
      mix_exs = File.read!(Path.join(@root, "apps/data/mix.exs"))

      refute mix_exs =~ ~r/\{:core,\s*in_umbrella/,
             "data must not depend on core; business rules do not belong in schemas"
    end

    test "utils depends on no sibling app — it is the leaf" do
      mix_exs = File.read!(Path.join(@root, "apps/utils/mix.exs"))

      refute mix_exs =~ ~r/in_umbrella/,
             "utils is the leaf: everything may depend on it, it depends on nothing"
    end

    test "core and notifire are siblings — neither may call the other" do
      # The `notifications` table is the seam: `core` decides what to say and
      # writes a row, `notifire` picks up unsent rows and delivers them. A
      # direct call would let a mailer being down fail the write that produced
      # the notification. A crontab entry naming a `notifire` worker lives in
      # config, not code — config is not a dependency.
      core = File.read!(Path.join(@root, "apps/core/mix.exs"))
      notifire = File.read!(Path.join(@root, "apps/notifire/mix.exs"))

      refute core =~ ~r/\{:notifire,\s*in_umbrella/,
             "core must not depend on notifire; write a notification row instead"

      refute notifire =~ ~r/\{:core,\s*in_umbrella/,
             "notifire must not depend on core; read rows, do not ask for them"
    end

    test "no API app depends on api — the endpoint sits on top of them all" do
      offenders =
        for app <- ~w(api_shared api_team api_client api_ext),
            File.read!(Path.join(@root, "apps/#{app}/mix.exs")) =~ ~r/\{:api,\s*in_umbrella/,
            do: app

      assert offenders == [], "these depend on api: #{inspect(offenders)}"
    end

    # **Every third-party dependency lives in `apps/utils/mix.exs`.** Two files
    # declaring the same dependency is two versions waiting to disagree.
    test "every dependency is declared in utils, and nowhere else" do
      offenders =
        for app <- @apps -- ["utils"],
            source = File.read!(Path.join(@root, "apps/#{app}/mix.exs")),
            [deps] <- Regex.scan(~r/defp deps do.*?\n  end/s, source),
            [_whole, name] <- Regex.scan(~r/\{:([a-z_0-9]+),/, deps),
            not (deps =~ ~r/\{:#{name},\s*in_umbrella: true\}/),
            do: "#{app}: #{name}"

      assert offenders == [],
             "add third-party deps to apps/utils/mix.exs only: #{inspect(offenders)}"
    end
  end
end
