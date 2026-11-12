defmodule Core.Leads.WordsTest do
  use ExUnit.Case, async: true

  alias Core.Leads.Words

  doctest Words

  test "states, outcomes and a day in the organisation's zone" do
    assert Words.state(:on_hold) == "On hold" and Words.state("todo") == "To do"
    assert Words.outcome(:position_closed) == "Position closed"
    assert Words.day(~U[2026-10-11 22:30:00Z], "Asia/Karachi") == "12 Oct"
    assert Words.day(nil, "Etc/UTC") == nil
  end
end
