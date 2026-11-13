defmodule Core.Meetings.Invite do
  @moduledoc """
  What an invitation (`.ics`) proposes (AQ-09 §9, PLAN §13.4), **pure**:
  the calendar's `METHOD` and its first `VEVENT`'s `UID`, `SEQUENCE`,
  `SUMMARY`, start and end, join link and `ORGANIZER`, read with
  `Core.Meetings.Ical`.

  - **Times:** `DTSTART`/`DTEND` in UTC (`…Z`), or local with a `TZID` —
    an IANA zone as written (or the last two parts of a path-like one),
    else the `VTIMEZONE`'s `X-LIC-LOCATION`, else its standard offset
    (`Etc/GMT-5` for +05:00; UTC for a half hour) — or floating, read in
    `default_zone`. A date alone is the whole day; no end is `DURATION`,
    else an hour.
  - **The join link:** `URL`, else `LOCATION` when it is a link, else
    Google's `X-GOOGLE-CONFERENCE`, else the first Zoom, Meet or Teams link
    in the description or the location. A `LOCATION` that isn't a link is
    the address.
  - **What it asks:** `REQUEST` (or `PUBLISH`, or none) proposes;
    `CANCEL`, or `STATUS:CANCELLED`, proposes the cancel. A `REPLY` or a
    `COUNTER` proposes nothing.
  - The platform is the link's (Zoom, Google Meet, Teams, Upwork), else
    *other*; the kind a guess from the title (*screening*, *technical*,
    *final*…), else *other* — both editable once it's a meeting.
  """

  alias Core.Meetings.Ical

  @meeting_links ~r{https://(?:[a-z0-9-]+\.)*zoom\.us/[^\s"'<>\\]+|https://meet\.google\.com/[a-z0-9-]+|https://teams\.(?:microsoft|live)\.com/[^\s"'<>\\]+}i

  @type t :: %{
          method: :request | :cancel,
          uid: String.t(),
          sequence: non_neg_integer(),
          title: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          time_zone: String.t(),
          join_url: String.t() | nil,
          address: String.t() | nil,
          organizer: String.t() | nil,
          organizer_email: String.t() | nil,
          platform: atom(),
          meeting_kind: atom()
        }

  @doc """
  `{:ok, invite}`, or `:none` when the text holds no event with a `UID`
  and a start, or asks nothing (a reply).
  """
  @spec read(String.t(), String.t()) :: {:ok, t()} | :none
  def read(text, default_zone \\ "Etc/UTC") when is_binary(text) do
    with [cal | _rest] <- Enum.filter(Ical.parse(text), &(&1.name == "VCALENDAR")),
         {:ok, method} <- method(Ical.value(cal, "METHOD")),
         event when not is_nil(event) <- event(cal),
         uid when is_binary(uid) <- blank(Ical.value(event, "UID")),
         {:ok, starts, zone, all_day?} <- time(cal, Ical.prop(event, "DTSTART"), default_zone) do
      ends = ends(cal, event, starts, all_day?, default_zone)
      {join_url, address} = place(event)
      title = title(Ical.value(event, "SUMMARY"))

      {:ok,
       %{
         method: if(cancelled?(event), do: :cancel, else: method),
         uid: String.slice(uid, 0, 500),
         sequence: sequence(Ical.value(event, "SEQUENCE")),
         title: title,
         starts_at: starts,
         ends_at: ends,
         time_zone: zone,
         join_url: join_url,
         address: address,
         organizer: organizer(Ical.prop(event, "ORGANIZER")),
         organizer_email: organizer_email(Ical.prop(event, "ORGANIZER")),
         platform: platform(join_url),
         meeting_kind: kind(title)
       }}
    else
      _nothing -> :none
    end
  end

  defp method(nil), do: {:ok, :request}

  defp method(value) do
    case String.upcase(String.trim(value)) do
      m when m in ["REQUEST", "PUBLISH"] -> {:ok, :request}
      "CANCEL" -> {:ok, :cancel}
      _reply_or_counter -> :none
    end
  end

  # The first event that is not one occurrence of a series.
  defp event(cal) do
    events = Ical.components(cal, "VEVENT")
    Enum.find(events, &is_nil(Ical.prop(&1, "RECURRENCE-ID"))) || List.first(events)
  end

  defp cancelled?(event),
    do: String.upcase(Ical.value(event, "STATUS") || "") == "CANCELLED"

  defp sequence(nil), do: 0

  defp sequence(value) do
    case Integer.parse(String.trim(value)) do
      {n, _rest} when n >= 0 -> n
      _bad -> 0
    end
  end

  defp title(nil), do: "Meeting"

  defp title(text) do
    case text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 200) do
      "" -> "Meeting"
      title -> title
    end
  end

  # ── Times ───────────────────────────────────────────────────────────────────

  defp time(_cal, nil, _default), do: :none

  defp time(cal, %{value: value, params: params}, default) do
    value = String.trim(value)

    cond do
      params["VALUE"] == "DATE" or Regex.match?(~r/^\d{8}$/, value) ->
        with {:ok, date} <- date(value),
             do: {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC"), "Etc/UTC", true}

      String.ends_with?(value, "Z") ->
        with {:ok, naive} <- naive(String.trim_trailing(value, "Z")),
             do: {:ok, DateTime.from_naive!(naive, "Etc/UTC"), "Etc/UTC", false}

      tzid = params["TZID"] ->
        with {:ok, naive} <- naive(value), do: local(naive, zone(cal, tzid))

      true ->
        with {:ok, naive} <- naive(value), do: local(naive, {default, 0})
    end
  end

  defp local(naive, {zone, offset}) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} ->
        {:ok, DateTime.shift_zone!(DateTime.add(at, -offset, :second), "Etc/UTC"), zone, false}

      {:ambiguous, first, _second} ->
        {:ok, DateTime.shift_zone!(first, "Etc/UTC"), zone, false}

      {:gap, _before, after_gap} ->
        {:ok, DateTime.shift_zone!(after_gap, "Etc/UTC"), zone, false}

      {:error, _unknown} ->
        {:ok, DateTime.from_naive!(naive, "Etc/UTC"), "Etc/UTC", false}
    end
  end

  # `{zone, extra offset in seconds}`: an IANA zone, or UTC with the
  # VTIMEZONE's standard offset when nothing better is known.
  defp zone(cal, tzid) do
    tzid = String.trim(tzid)
    tail = tzid |> String.split("/") |> Enum.take(-2) |> Enum.join("/")

    cond do
      known?(tzid) -> {tzid, 0}
      known?(tail) -> {tail, 0}
      (location = location(cal, tzid)) && known?(location) -> {location, 0}
      offset = offset(cal, tzid) -> by_offset(offset)
      true -> {"Etc/UTC", 0}
    end
  end

  defp known?(zone) when is_binary(zone) and zone != "",
    do: match?({:ok, _now}, DateTime.now(zone))

  defp known?(_zone), do: false

  defp vtimezone(cal, tzid),
    do: Enum.find(Ical.components(cal, "VTIMEZONE"), &(Ical.value(&1, "TZID") == tzid))

  defp location(cal, tzid) do
    case vtimezone(cal, tzid) do
      nil -> nil
      tz -> Ical.value(tz, "X-LIC-LOCATION")
    end
  end

  defp offset(cal, tzid) do
    with %{} = tz <- vtimezone(cal, tzid),
         [standard | _rest] <- Ical.components(tz, "STANDARD") ++ Ical.components(tz, "DAYLIGHT"),
         to when is_binary(to) <- Ical.value(standard, "TZOFFSETTO"),
         [_all, sign, hh, mm] <- Regex.run(~r/^([+-])(\d{2})(\d{2})/, String.trim(to)) do
      seconds = String.to_integer(hh) * 3600 + String.to_integer(mm) * 60
      if sign == "-", do: -seconds, else: seconds
    else
      _none -> nil
    end
  end

  # Whole hours have an IANA name (Etc's signs are POSIX's: Etc/GMT-5 is +05:00).
  defp by_offset(0), do: {"Etc/UTC", 0}

  defp by_offset(seconds) when rem(seconds, 3600) == 0 do
    hours = div(seconds, 3600)
    name = if hours > 0, do: "Etc/GMT-#{hours}", else: "Etc/GMT+#{-hours}"
    if known?(name), do: {name, 0}, else: {"Etc/UTC", seconds}
  end

  defp by_offset(seconds), do: {"Etc/UTC", seconds}

  defp ends(cal, event, starts, all_day?, default) do
    with %{} = prop <- Ical.prop(event, "DTEND"),
         {:ok, ends, _zone, _all_day} <- time(cal, prop, default),
         true <- DateTime.after?(ends, starts) do
      ends
    else
      _no_end -> DateTime.add(starts, duration(Ical.value(event, "DURATION"), all_day?), :second)
    end
  end

  defp duration(nil, true), do: 86_400
  defp duration(nil, false), do: 3600

  defp duration(text, all_day?) do
    case Regex.run(
           ~r/^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/,
           String.trim(text)
         ) do
      [_all | parts] ->
        [w, d, h, m, s] =
          parts |> Enum.concat(List.duplicate("", 5)) |> Enum.take(5) |> Enum.map(&int/1)

        case w * 604_800 + d * 86_400 + h * 3600 + m * 60 + s do
          0 -> duration(nil, all_day?)
          seconds -> seconds
        end

      nil ->
        duration(nil, all_day?)
    end
  end

  defp int(""), do: 0
  defp int(digits), do: String.to_integer(digits)

  defp date(<<y::binary-4, m::binary-2, d::binary-2>>), do: Date.new(int(y), int(m), int(d))
  defp date(_bad), do: :none

  defp naive(<<date::binary-8, "T", h::binary-2, mi::binary-2, s::binary-2, _rest::binary>>) do
    with {:ok, day} <- date(date),
         {:ok, time} <- Time.new(int(h), int(mi), int(s)),
         do: NaiveDateTime.new(day, time)
  end

  defp naive(_bad), do: :none

  # ── Where ───────────────────────────────────────────────────────────────────

  defp place(event) do
    location = Ical.value(event, "LOCATION") |> blank()

    join =
      Enum.find_value(
        [
          Ical.value(event, "URL"),
          location,
          Ical.value(event, "X-GOOGLE-CONFERENCE")
        ],
        &link/1
      ) ||
        first_meeting_link([
          Ical.value(event, "DESCRIPTION"),
          Ical.value(event, "X-ALT-DESC"),
          location
        ])

    address = if location && is_nil(link(location)), do: String.slice(location, 0, 500)
    {join, address}
  end

  defp link(nil), do: nil

  defp link(text) do
    text = String.trim(text)

    case URI.new(text) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if String.length(text) <= 2000, do: text

      _not_a_link ->
        nil
    end
  end

  defp first_meeting_link(texts) do
    texts
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn text ->
      case Regex.run(@meeting_links, text) do
        [url | _rest] -> link(String.trim_trailing(url, "."))
        nil -> nil
      end
    end)
  end

  defp organizer_email(nil), do: nil

  defp organizer_email(%{value: value}) do
    email = value |> String.replace(~r/^mailto:/i, "") |> String.trim() |> String.downcase()
    if String.contains?(email, "@"), do: email
  end

  defp organizer(nil), do: nil

  defp organizer(%{params: params, value: value}) do
    email = value |> String.replace(~r/^mailto:/i, "") |> String.trim() |> blank()
    name = blank(params["CN"])
    (name || email) && String.slice(name || email, 0, 200)
  end

  @doc ~S"""
  The platform a join link is on.

      iex> Core.Meetings.Invite.platform("https://meet.google.com/abc-defg-hij")
      :google_meet
      iex> Core.Meetings.Invite.platform("https://corvid.zoom.us/j/123")
      :zoom
      iex> Core.Meetings.Invite.platform(nil)
      :other
  """
  @spec platform(String.t() | nil) :: atom()
  def platform(nil), do: :other

  def platform(url) do
    host = (URI.parse(url).host || "") |> String.downcase()

    cond do
      host == "zoom.us" or String.ends_with?(host, ".zoom.us") -> :zoom
      host == "meet.google.com" -> :google_meet
      host in ["teams.microsoft.com", "teams.live.com"] -> :teams
      host == "upwork.com" or String.ends_with?(host, ".upwork.com") -> :upwork
      true -> :other
    end
  end

  @doc ~S"""
  A meeting kind guessed from a title.

      iex> Core.Meetings.Invite.kind("Technical interview · Corvid Security")
      :technical
      iex> Core.Meetings.Invite.kind("Intro call")
      :other
  """
  @spec kind(String.t()) :: atom()
  def kind(title) do
    cond do
      title =~ ~r/screen/i -> :screening
      title =~ ~r/\bai\b.*interview/i -> :ai_interview
      title =~ ~r/technical|coding|system design|pair(ing)?\b/i -> :technical
      title =~ ~r/assessment|take.?home/i -> :assessment_review
      title =~ ~r/\bfinal\b/i -> :final
      true -> :other
    end
  end

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
