defmodule Core.Conversations.TreeTest do
  @moduledoc "AQ-06 §7.1, the pure tree: JWZ's parent, the gaps, children oldest first, a cycle placed once."

  use ExUnit.Case, async: true

  alias Core.Conversations.Tree

  doctest Tree

  defp m(id, parent, sent, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        parent_message_id: parent,
        sent_at: DateTime.add(~U[2026-11-01 09:00:00Z], sent, :second),
        in_reply_to: nil,
        references: [],
        rfc_message_id: nil
      },
      extra
    )
  end

  defp node(msg, children, gap), do: {msg.id, gap, children}

  test "roots oldest first, children oldest first; a parent outside the set makes a root" do
    messages = [m("c", "a", 3), m("b", "a", 2), m("a", nil, 1), m("d", "x", 0)]

    assert Tree.build(messages, &node/3) ==
             {[{"d", false, []}, {"a", false, [{"b", false, []}, {"c", false, []}]}], 0}
  end

  test "a reply whose In-Reply-To is not held is a gap, counted; held, it is not" do
    held = m("p", nil, 1, %{rfc_message_id: "p@x"})
    child = m("c", nil, 2, %{in_reply_to: "q@x", references: ["p@x", "q@x"]})
    assert {[{"p", false, []}, {"c", true, []}], 1} = Tree.build([held, child], &node/3)

    filled = m("q", "p", 1, %{rfc_message_id: "q@x", in_reply_to: "p@x"})
    child = %{child | parent_message_id: "q"}

    assert {[{"p", false, [{"q", false, [{"c", false, []}]}]}], 0} =
             Tree.build([held, filled, child], &node/3)
  end

  test "a cycle (a bad edit) places each message once" do
    assert {[], 0} = Tree.build([m("a", "b", 1), m("b", "a", 2)], &node/3)
  end
end
