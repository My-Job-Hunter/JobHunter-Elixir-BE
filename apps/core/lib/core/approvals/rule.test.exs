defmodule Core.Approvals.RuleTest do
  @moduledoc """
  AQ-07 §6 and QP7-5, the pure rule, as a table: the outcome of one
  version's decisions over the slots, under *any* and *all*.
  """

  use ExUnit.Case, async: true

  alias Core.Approvals.Rule

  @slots [%{id: "c"}, %{id: "t"}, %{id: "u"}]

  defp said(pairs),
    do: Enum.map(pairs, fn {id, d} -> %{approval_reviewer_id: id, decision: d} end)

  @table [
    # {rule, decisions, outcome}
    {:any, [], :pending},
    {:all, [], :pending},
    {:any, [{"c", :approved}], :approved},
    {:all, [{"c", :approved}], :pending},
    {:all, [{"c", :approved}, {"t", :approved}], :pending},
    {:all, [{"c", :approved}, {"t", :approved}, {"u", :approved}], :approved},
    {:any, [{"c", :rejected}], :rejected},
    {:all, [{"c", :rejected}], :rejected},
    {:any, [{"c", :changes_requested}], :changes_requested},
    {:all, [{"c", :approved}, {"t", :changes_requested}], :changes_requested},
    # Any rejection rejects, even beside a request for changes and a yes.
    {:all, [{"c", :changes_requested}, {"t", :rejected}, {"u", :approved}], :rejected},
    {:any, [{"c", :approved}, {"t", :rejected}], :rejected},
    {:any, [{"c", :approved}, {"t", :changes_requested}], :changes_requested}
  ]

  for {{rule, decisions, outcome}, i} <- Enum.with_index(@table) do
    test "row #{i + 1}: #{rule} over #{inspect(decisions)} is #{outcome}" do
      assert Rule.outcome(unquote(rule), @slots, said(unquote(Macro.escape(decisions)))) ==
               unquote(outcome)
    end
  end

  test "all over no slots never approves" do
    assert Rule.outcome(:all, [], said([{"x", :approved}])) == :pending
  end

  test "the open slots are those without a decision on the version" do
    assert Enum.map(Rule.open(@slots, said([{"t", :approved}])), & &1.id) == ["c", "u"]
    assert Rule.open(@slots, said([{"c", :approved}, {"t", :rejected}, {"u", :approved}])) == []
  end
end
