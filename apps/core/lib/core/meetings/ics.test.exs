defmodule Core.Meetings.IcsTest do
  @moduledoc "AQ-06 §8.2, QP6-19, the pure file and the meetings' words: escaped, folded, CRLF."

  use ExUnit.Case, async: true

  alias Core.Meetings.{Ics, Words}

  doctest Ics
  doctest Words

  test "one VEVENT; a long line folded at 75 octets; every line ends CRLF" do
    meeting = %{
      id: "m-1",
      title: "Technical interview",
      starts_at: ~U[2026-11-18 09:00:00Z],
      ends_at: ~U[2026-11-18 10:00:00Z],
      updated_at: ~U[2026-11-11 09:00:00Z],
      status: :scheduled,
      sequence: 3,
      join_url: "https://meet.google.com/abc-defg-hij",
      address: nil
    }

    ics =
      Ics.render(meeting, String.duplicate("Long title, with commas; ", 5), [
        "Backend Developer · Golang"
      ])

    lines = String.split(ics, "\r\n", trim: true)
    assert Enum.all?(lines, &(byte_size(&1) <= 75))
    unfolded = String.replace(ics, "\r\n ", "")
    assert ics =~ "SEQUENCE:3\r\n" and ics =~ "UID:m-1@autoqare\r\n"

    assert unfolded =~
             "DESCRIPTION:https://meet.google.com/abc-defg-hij\\nBackend Developer · Golang\r\n"

    assert unfolded =~ "SUMMARY:Long title\\, with commas\\; "
    assert String.ends_with?(ics, "END:VCALENDAR\r\n")
  end
end
