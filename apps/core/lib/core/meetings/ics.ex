defmodule Core.Meetings.Ics do
  @moduledoc """
  A meeting as a calendar file (AQ-06 §8.2, QP6-19), **pure**: one VEVENT
  with a stable `UID` (the meeting's id), `SEQUENCE` as stored (+1 per
  change), `METHOD:PUBLISH`, the times in UTC, the join link in `LOCATION`
  and `DESCRIPTION`; a cancelled meeting's file says `STATUS:CANCELLED`.
  No calendar sync (Q24). RFC 5545: CRLF line ends, text escaped, lines
  folded at 75 octets.
  """

  alias Core.Meetings.Words

  @doc """
  The file for `meeting` (`id`, `title`, `starts_at`, `ends_at`, `status`,
  `sequence`, `join_url`, `address`, `updated_at`, `platform`) with
  `summary` (the event's name) and `description` lines (what the reader
  may read). `method` is `PUBLISH` for the download; an email's invite is
  `REQUEST`, or `CANCEL` for a cancelled meeting (AQ-08 §11.4).
  """
  @spec render(map(), String.t(), [String.t()], String.t()) :: String.t()
  def render(meeting, summary, description, method \\ "PUBLISH") do
    location = meeting.join_url || meeting.address
    description = Enum.reject([meeting.join_url | description], &is_nil/1)

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//AutoQare//Meetings//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:#{method}",
      "BEGIN:VEVENT",
      "UID:#{meeting.id}@autoqare",
      "DTSTAMP:#{stamp(meeting.updated_at || meeting.starts_at)}",
      "SEQUENCE:#{meeting.sequence}",
      "DTSTART:#{stamp(meeting.starts_at)}",
      "DTEND:#{stamp(meeting.ends_at)}",
      "SUMMARY:#{escape(summary)}",
      location && "LOCATION:#{escape(location)}",
      description != [] && "DESCRIPTION:#{escape(Enum.join(description, "\n"))}",
      meeting.join_url && "URL:#{meeting.join_url}",
      "STATUS:#{status(meeting.status)}",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join("", &(fold(&1) <> "\r\n"))
  end

  @doc """
  A meeting's file as both apps and its emails give it (AQ-06 §8.2): the
  title and company as the event's name, then the job, the profile and the
  platform; the meeting is read with its lead, job, company and profile.
  `method` as `render/4` takes it.
  """
  @spec for_meeting(map(), String.t()) :: String.t()
  def for_meeting(meeting, method \\ "PUBLISH") do
    job = meeting.lead.job
    summary = if job.company, do: "#{meeting.title} · #{job.company.name}", else: meeting.title
    about = "#{job.title} · #{meeting.lead.profile.title} · #{Words.platform(meeting.platform)}"
    render(meeting, summary, [about], method)
  end

  defp status(:cancelled), do: "CANCELLED"
  defp status(_scheduled_or_past), do: "CONFIRMED"

  @doc ~S"""
  An instant as iCalendar's UTC form.

      iex> Core.Meetings.Ics.stamp(~U[2026-11-18 09:05:00.123456Z])
      "20261118T090500Z"
  """
  @spec stamp(DateTime.t()) :: String.t()
  def stamp(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  @doc ~S"""
  Text escaped (RFC 5545 §3.3.11).

      iex> Core.Meetings.Ics.escape("a, b; c\\d\ne")
      "a\\, b\\; c\\\\d\\ne"
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r?\n/, "\\n")
  end

  # Lines longer than 75 octets continue on the next, after a space.
  defp fold(line) when byte_size(line) <= 75, do: line

  defp fold(line) do
    {head, rest} = split_at(line, 75)
    head <> "\r\n " <> fold_rest(rest)
  end

  defp fold_rest(rest) when byte_size(rest) <= 74, do: rest

  defp fold_rest(rest) do
    {head, tail} = split_at(rest, 74)
    head <> "\r\n " <> fold_rest(tail)
  end

  # Never inside a UTF-8 character.
  defp split_at(text, bytes) do
    cut = Enum.find(bytes..1//-1, &String.valid?(binary_part(text, 0, &1))) || bytes
    {binary_part(text, 0, cut), binary_part(text, cut, byte_size(text) - cut)}
  end
end
