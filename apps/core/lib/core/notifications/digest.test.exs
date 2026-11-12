defmodule Core.Notifications.DigestTest do
  @moduledoc "What a digest says, and when (AQ-08 §7.4, §11.4): pure."

  use ExUnit.Case, async: true

  alias Core.Notifications.Digest

  doctest Digest

  @groups [
    %{key: "tasks", label: "Tasks"},
    %{key: "leads", label: "Leads"},
    %{key: "conversations", label: "Conversations"}
  ]

  defp row(title, group), do: %{title: title, group: group}

  test "nothing to say, no digest" do
    assert Digest.compose([], @groups) == nil
  end

  test "a line per group in the groups' order, then the titles oldest first" do
    rows = [
      row("Follow up on “Golang”", "leads"),
      row("“Fix the CV” is overdue", "tasks"),
      row("New in Triage: Mei Chen", "conversations"),
      row("“Send the rate” is overdue", "tasks")
    ]

    assert %{title: "4 things you haven't read", body: body} = Digest.compose(rows, @groups)

    assert body ==
             Enum.join(
               [
                 "Tasks · 2",
                 "Leads · 1",
                 "Conversations · 1",
                 "",
                 "Follow up on “Golang”",
                 "“Fix the CV” is overdue",
                 "New in Triage: Mei Chen",
                 "“Send the rate” is overdue"
               ],
               "\n"
             )
  end

  test "at most 50 titles, then \"and N more\"; the count is all of them" do
    rows = for n <- 1..62, do: row("Task #{n} is overdue", "tasks")
    %{title: title, body: body} = Digest.compose(rows, @groups)

    assert title == "62 things you haven't read"
    lines = String.split(body, "\n")
    assert hd(lines) == "Tasks · 62"
    assert Enum.at(lines, 2) == "Task 1 is overdue"
    assert Enum.at(lines, 51) == "Task 50 is overdue"
    assert List.last(lines) == "and 12 more"
    assert length(lines) == 53
  end

  test "due once the person's time has passed today in their zone; the key is that local date" do
    # 08:00 in Karachi is 03:00 UTC; in New York 08:00 is 13:00 UTC.
    assert Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-12 02:59:00Z]) == :not_yet

    assert Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-12 03:00:00Z]) ==
             {:due, ~D[2026-11-12]}

    # 22:00 UTC is 03:00 on the 13th in Karachi: not yet; at 03:30 UTC the 13th's is due.
    assert Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-12 22:00:00Z]) == :not_yet

    assert Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-13 03:30:00Z]) ==
             {:due, ~D[2026-11-13]}

    assert Digest.due(~T[08:00:00], "America/New_York", ~U[2026-11-12 12:00:00Z]) == :not_yet
  end
end
