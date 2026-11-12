defmodule Utils.UnitsTest do
  use ExUnit.Case, async: true

  alias Utils.Units

  doctest Units

  test "every period but a project converts to a year by QP3-9's factors" do
    assert Units.annualise(100, :hour) == 208_000
    assert Units.annualise(100, :day) == 26_000
    assert Units.annualise(100, :week) == 5_200
    assert Units.annualise(100, :month) == 1_200
    assert Units.annualise(100, "year") == 100
    assert Units.annualise(100, :project) == nil
    assert Units.annualise(nil, :year) == nil
  end

  test "a project budget compares only with a project budget" do
    assert Units.comparable({150_000, :project}, {100_000, :project}) == {150_000, 100_000}
    assert Units.comparable({4_500, :hour}, {150_000, :project}) == nil
  end
end
