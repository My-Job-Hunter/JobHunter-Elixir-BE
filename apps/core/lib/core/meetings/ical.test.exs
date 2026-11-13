defmodule Core.Meetings.IcalTest do
  @moduledoc "The iCalendar reader (AQ-09 §9): unfolding, parameters, nesting, TEXT."

  use ExUnit.Case, async: true

  alias Core.Meetings.Ical

  doctest Ical

  test "nests VTIMEZONE and VEVENT, keeps properties in order, upper-cases names" do
    text = """
    begin:VCALENDAR
    METHOD:REQUEST
    BEGIN:VTIMEZONE
    TZID:Custom Zone
    BEGIN:STANDARD
    TZOFFSETTO:+0530
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    uid:abc@corvid.example
    ATTENDEE;CN=One:mailto:one@corvid.example
    ATTENDEE;CN=Two:mailto:two@corvid.example
    END:VEVENT
    END:VCALENDAR
    """

    assert [%{name: "VCALENDAR"} = cal] = Ical.parse(text)
    assert [tz] = Ical.components(cal, "VTIMEZONE")
    assert [standard] = Ical.components(tz, "STANDARD")
    assert Ical.value(standard, "TZOFFSETTO") == "+0530"
    assert [event] = Ical.components(cal, "VEVENT")
    assert Ical.value(event, "UID") == "abc@corvid.example"

    assert Enum.map(Enum.filter(event.props, &(&1.name == "ATTENDEE")), & &1.params["CN"]) == [
             "One",
             "Two"
           ]
  end

  test "a line without a colon, a stray END and blank lines are skipped" do
    assert [%{name: "VCALENDAR", props: [%{name: "METHOD", value: "CANCEL"}]}] =
             Ical.parse("END:VEVENT\n\nBEGIN:VCALENDAR\nnonsense\nMETHOD:CANCEL\nEND:VCALENDAR\n")
  end

  test "a value keeps its colons; a quoted parameter keeps its semicolon" do
    assert %{params: %{"CN" => "Haddad; Omar"}, value: "mailto:omar@corvid.example"} =
             Ical.line(~s|ORGANIZER;CN="Haddad; Omar":mailto:omar@corvid.example|)

    assert %{value: "https://corvid.zoom.us/j/1?pwd=a:b"} =
             Ical.line("URL:https://corvid.zoom.us/j/1?pwd=a:b")
  end
end
