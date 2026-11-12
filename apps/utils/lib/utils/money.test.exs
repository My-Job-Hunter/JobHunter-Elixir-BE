defmodule Utils.MoneyTest do
  use ExUnit.Case, async: true

  alias Utils.Money

  doctest Money

  test "a project budget reads with its period, and a zero-digit currency has no fraction" do
    assert Money.line(%{
             min_minor: 150_000,
             max_minor: 150_000,
             currency: "JPY",
             period: :project
           }) ==
             "JPY 150,000 / project"
  end

  test "posting words stand in when there is no amount" do
    assert Money.line(%{min_minor: nil, max_minor: nil, text: "Competitive"}) == "Competitive"
  end

  test "a negative amount keeps its sign" do
    assert Money.amount(-1_050, "USD") == "-10.50"
  end
end
