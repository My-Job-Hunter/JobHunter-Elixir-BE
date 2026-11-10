defmodule Data.VocabularyTest do
  @moduledoc """
  The shared strings, asserted against the file the frontend reads.
  """

  use ExUnit.Case, async: true

  alias Data.Vocabulary

  doctest Vocabulary

  test "priv/vocabulary.json is what the module says — run `mix jh.vocabulary` if not" do
    assert File.read!(Vocabulary.json_path()) == Vocabulary.to_json(),
           "apps/data/priv/vocabulary.json is out of date: run `mix jh.vocabulary`"
  end

  test "the exported keys are sorted and every list keeps its order" do
    decoded = Jason.decode!(File.read!(Vocabulary.json_path()), objects: :ordered_objects)
    keys = Enum.map(decoded.values, fn {key, _values} -> key end)

    assert keys == Enum.sort(keys)

    for {key, values} <- decoded.values do
      assert values == Map.fetch!(Vocabulary.all(), String.to_existing_atom(key))
    end
  end

  test "no list repeats a value" do
    for {name, values} <- Vocabulary.all() do
      assert values == Enum.uniq(values), "#{name} repeats a value"
    end
  end

  # The lists the plan fixes word for word (PLAN §1, §6.2, §9). A change here
  # is a change to the frontend's packages/core in the same breath.
  test "states and stages, in their order" do
    assert Vocabulary.lead_states() == ~w(to_do in_progress on_hold done archived)

    assert Vocabulary.stage_kinds() ==
             ~w(inbound applied seen screening assessment interview ai_interview final offer negotiation contract)

    assert Vocabulary.task_statuses() == ~w(draft todo in_progress on_hold done closed archived)

    assert Vocabulary.approval_states() ==
             ~w(draft pending approved changes_requested rejected withdrawn expired)
  end

  test "team roles are organisation roles" do
    assert Vocabulary.team_member_roles() -- Vocabulary.roles() == []
  end

  test "a custom stage needs a slug" do
    assert Vocabulary.custom_stage?("custom.portfolio_review")
    refute Vocabulary.custom_stage?("custom.")
    refute Vocabulary.custom_stage?("offer")
  end
end
