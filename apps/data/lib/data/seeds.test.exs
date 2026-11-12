defmodule Data.SeedsTest do
  @moduledoc """
  What gets seeded, and in what order. The reference seed holds the
  notification groups and kinds (P2) and the extension's selector
  documents (P5), the production seed the skills
  vocabulary (P1.2) after them; the demo seed is empty by design.
  """

  use Data.DataCase, async: true

  alias Data.Seeds

  describe "the plan" do
    test "every entry says why it sits where it does" do
      for kind <- Seeds.kinds(), entry <- Seeds.plan(kind) do
        assert is_binary(entry.because) and String.length(entry.because) > 40,
               "#{entry.key} does not say why it is ordered where it is"
      end
    end

    test "every entry can actually be called" do
      for kind <- Seeds.kinds(), entry <- Seeds.plan(kind) do
        arity = length(entry.args.([]))
        {:module, _loaded} = Code.ensure_loaded(entry.module)

        assert function_exported?(entry.module, entry.fun, arity),
               "#{inspect(entry.module)}.#{entry.fun}/#{arity} does not exist"
      end
    end

    test "the production seed starts with every reference group" do
      reference = Seeds.plan(:reference)

      assert Enum.take(Seeds.plan(:prod), length(reference)) == reference
    end

    test "a kind still empty says what it will hold" do
      for kind <- Seeds.kinds(), Seeds.plan(kind) == [] do
        assert [_ | _] = Seeds.coming(kind)
        assert Seeds.summary(kind, []) =~ "Nothing to load yet"
      end
    end
  end

  describe "run" do
    test "an empty kind runs and loads nothing; reference and production run their groups" do
      # The suite's database ran the reference seed before the suite: both
      # sites' selector documents are there already, so both are kept.
      assert {:ok,
              [
                {"the notification groups and kinds", %{kept: 36}},
                {"the extension's selector documents", %{inserted: 0, kept: 2}}
              ]} = Seeds.run(:reference)

      assert Seeds.run(:demo) == {:ok, []}

      assert {:ok,
              [
                {"the notification groups and kinds", %{inserted: 0, updated: 0, kept: 36}},
                {"the extension's selector documents", %{inserted: 0, kept: 2}},
                {"the skills vocabulary", %{inserted: 0, kept: 0}}
              ]} = Seeds.run(:prod)

      assert Seeds.summary(:prod, [{"the skills vocabulary", %{inserted: 120, kept: 3}}]) =~
               "(123)"
    end

    test "refuses an unknown group by name, rather than seeding nothing" do
      assert {:error, message} = Seeds.run(:reference, only: "platfroms")
      assert message =~ "platfroms"
    end
  end
end
