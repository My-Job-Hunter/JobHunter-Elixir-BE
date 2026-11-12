defmodule Core.Ingest.Conversation.SentTextTest do
  @moduledoc "AQ-06 §9: a chat row's raw time, read in the customer's zone, the day carried forward."

  use ExUnit.Case, async: true

  alias Core.Ingest.Conversation.SentText

  doctest SentText

  @at ~U[2026-11-11 10:00:00Z]

  test "Upwork's bare times inherit the day before; Just now and nonsense are the capture's moment" do
    assert SentText.place(["Nov 9 9:00 PM", "9:30 PM", "Just now", "?"], @at, "Etc/UTC") == [
             ~U[2026-11-09 21:00:00.000000Z],
             ~U[2026-11-09 21:30:00.000000Z],
             ~U[2026-11-11 10:00:00.000000Z],
             ~U[2026-11-11 10:00:00.000001Z]
           ]
  end

  test "an ISO time is kept exact; 3 Nov 2025 and noon-ish forms read" do
    assert SentText.read("2026-11-05T10:00:00+05:00", ~D[2026-11-11]) ==
             {:instant, ~U[2026-11-05 05:00:00Z]}

    assert SentText.read("3 Nov 2025, 12:05 PM", ~D[2026-11-11]) ==
             {:at, ~D[2025-11-03], ~T[12:05:00]}

    assert SentText.read("12:30 AM", ~D[2026-11-11]) == {:time, ~T[00:30:00]}
  end
end
