defmodule Core.Meetings.InviteTest do
  @moduledoc "An invitation read (AQ-09 §9): the run's three files, and the zones, ends and links."

  use ExUnit.Case, async: true

  alias Core.Conversations.Eml
  alias Core.Meetings.Invite

  doctest Invite

  defp calendar(name) do
    {:ok, mail} = Eml.parse(File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__)))
    mail.calendar
  end

  defp event(lines, extra \\ "") do
    """
    BEGIN:VCALENDAR
    METHOD:REQUEST
    #{extra}BEGIN:VEVENT
    UID:x@corvid.example
    #{lines}
    END:VEVENT
    END:VCALENDAR
    """
  end

  test "the run's invitation: REQUEST, then SEQUENCE 1, then CANCEL" do
    assert {:ok, one} = Invite.read(calendar("invite-request.eml"))

    assert %{
             method: :request,
             uid: "corvid-interview-7@corvid.example",
             sequence: 0,
             title: "Technical interview",
             starts_at: ~U[2026-11-18 09:00:00Z],
             ends_at: ~U[2026-11-18 10:00:00Z],
             time_zone: "Asia/Karachi",
             join_url: "https://meet.google.com/abc-defg-hij",
             address: nil,
             organizer: "Omar Haddad",
             organizer_email: "omar.haddad@corvid.example",
             platform: :google_meet,
             meeting_kind: :technical
           } = one

    assert {:ok, %{sequence: 1, starts_at: ~U[2026-11-19 10:00:00Z]}} =
             Invite.read(calendar("invite-sequence-1.eml"))

    assert {:ok, %{method: :cancel, sequence: 2}} = Invite.read(calendar("invite-cancel.eml"))
  end

  test "UTC, floating in the default zone, a date alone, DURATION" do
    assert {:ok,
            %{
              starts_at: ~U[2026-11-18 09:00:00Z],
              ends_at: ~U[2026-11-18 09:30:00Z],
              time_zone: "Etc/UTC"
            }} =
             Invite.read(event("DTSTART:20261118T090000Z\nDURATION:PT30M"))

    assert {:ok, %{starts_at: ~U[2026-11-18 09:00:00Z], time_zone: "Asia/Karachi"}} =
             Invite.read(event("DTSTART:20261118T140000"), "Asia/Karachi")

    assert {:ok, %{starts_at: ~U[2026-11-18 00:00:00Z], ends_at: ~U[2026-11-19 00:00:00Z]}} =
             Invite.read(event("DTSTART;VALUE=DATE:20261118"))

    assert {:ok, %{ends_at: ~U[2026-11-18 10:00:00Z]}} =
             Invite.read(event("DTSTART:20261118T090000Z"))
  end

  test "a TZID that isn't IANA: a path's tail, X-LIC-LOCATION, else the standard offset" do
    assert {:ok, %{time_zone: "Europe/Berlin", starts_at: ~U[2026-11-18 13:00:00Z]}} =
             Invite.read(
               event(~s|DTSTART;TZID=/mozilla.org/20050126_1/Europe/Berlin:20261118T140000|)
             )

    zone = fn body -> "BEGIN:VTIMEZONE\nTZID:Pakistan Standard Time\n#{body}END:VTIMEZONE\n" end

    assert {:ok, %{time_zone: "Asia/Karachi", starts_at: ~U[2026-11-18 09:00:00Z]}} =
             Invite.read(
               event(
                 "DTSTART;TZID=Pakistan Standard Time:20261118T140000",
                 zone.("X-LIC-LOCATION:Asia/Karachi\n")
               )
             )

    assert {:ok, %{time_zone: "Etc/GMT-5", starts_at: ~U[2026-11-18 09:00:00Z]}} =
             Invite.read(
               event(
                 "DTSTART;TZID=Pakistan Standard Time:20261118T140000",
                 zone.("BEGIN:STANDARD\nTZOFFSETTO:+0500\nEND:STANDARD\n")
               )
             )

    assert {:ok, %{time_zone: "Etc/UTC", starts_at: ~U[2026-11-18 08:30:00Z]}} =
             Invite.read(
               event(
                 "DTSTART;TZID=India Standard Time:20261118T140000",
                 String.replace(
                   zone.("BEGIN:STANDARD\nTZOFFSETTO:+0530\nEND:STANDARD\n"),
                   "Pakistan",
                   "India"
                 )
               )
             )
  end

  test "the join link: URL first, a Zoom link in the description, a place that isn't a link" do
    assert {:ok,
            %{
              join_url: "https://corvid.zoom.us/j/42",
              platform: :zoom,
              address: "Room 4, Corvid HQ"
            }} =
             Invite.read(
               event(
                 "DTSTART:20261118T090000Z\nLOCATION:Room 4\\, Corvid HQ\nDESCRIPTION:Dial in: https://corvid.zoom.us/j/42 or call"
               )
             )

    assert {:ok, %{join_url: "https://teams.microsoft.com/l/meetup-join/abc", platform: :teams}} =
             Invite.read(
               event(
                 "DTSTART:20261118T090000Z\nURL:https://teams.microsoft.com/l/meetup-join/abc"
               )
             )
  end

  test "a reply, no UID or no start proposes nothing; STATUS:CANCELLED is a cancel" do
    assert Invite.read(String.replace(event("DTSTART:20261118T090000Z"), "REQUEST", "REPLY")) ==
             :none

    assert Invite.read(
             "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261118T090000Z\nEND:VEVENT\nEND:VCALENDAR"
           ) == :none

    assert Invite.read(event("SUMMARY:No start")) == :none
    assert Invite.read("not a calendar") == :none

    assert {:ok, %{method: :cancel, title: "Meeting"}} =
             Invite.read(event("DTSTART:20261118T090000Z\nSTATUS:CANCELLED"))
  end
end
