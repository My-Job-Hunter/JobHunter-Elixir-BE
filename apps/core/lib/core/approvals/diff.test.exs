defmodule Core.Approvals.DiffTest do
  @moduledoc """
  AQ-07 §6 and QP7-8, the pure diff: word by word for the body and the
  proposed texts, old → new for money, the CV, Connects and skills; only
  what changed, in a fixed order.
  """

  use ExUnit.Case, async: true

  alias Core.Approvals.Diff

  doctest Diff

  test "the body word by word, a sentence added" do
    before = %{body_md: "I can start Monday."}
    now = %{body_md: "I can start Monday. I have shipped Go at scale."}

    assert [%{field: "body_md", parts: parts}] = Diff.between(before, now)

    assert parts == [
             %{op: "same", text: "I can start Monday."},
             %{op: "added", text: " I have shipped Go at scale."}
           ]
  end

  test "money and the CV read old → new; an unchanged field says nothing" do
    before = %{body_md: "Same", bid: "USD 45 / hour", document: "Golang · v3"}
    now = %{body_md: "Same", bid: "USD 50 / hour", document: "Golang · v4"}

    assert Diff.between(before, now) == [
             %{
               field: "document",
               parts: [%{op: "removed", text: "Golang · v3"}, %{op: "added", text: "Golang · v4"}]
             },
             %{
               field: "bid",
               parts: [
                 %{op: "removed", text: "USD 45 / hour"},
                 %{op: "added", text: "USD 50 / hour"}
               ]
             }
           ]
  end

  test "a value added or taken away shows one side; whitespace alone is no change" do
    assert Diff.between(%{connects: nil}, %{connects: "12 Connects"}) == [
             %{field: "connects", parts: [%{op: "added", text: "12 Connects"}]}
           ]

    assert Diff.between(%{title: "Go engineer"}, %{title: nil}) == [
             %{field: "title", parts: [%{op: "removed", text: "Go engineer"}]}
           ]

    assert Diff.between(%{body_md: "Hello "}, %{body_md: "Hello"}) == []
  end
end
