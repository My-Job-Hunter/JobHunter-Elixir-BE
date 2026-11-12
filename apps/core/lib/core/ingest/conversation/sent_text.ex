defmodule Core.Ingest.Conversation.SentText do
  @moduledoc """
  When a captured chat message was sent (AQ-06 §9), **pure**: the page's
  raw words — LinkedIn's "Nov 3 10:42 AM", "Today 9:15 AM", "Yesterday
  4:01 PM", "Mon 3:00 PM", a bare "11:05 AM"; Upwork's "2:15 PM" — read
  against the capture's moment in the customer's zone. **A bare time
  takes the day of the row before it**, in order (the first row's, today);
  a day with no time is its start; anything unreadable, or "Just now", is
  the capture's moment. Rows that would land on the same instant keep
  their order a microsecond apart.
  """

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @days ~w(mon tue wed thu fri sat sun)

  @doc """
  Each `sent_text` of `rows` placed: the rows' `sent_at` (UTC), in order.

      iex> at = ~U[2026-11-11 10:00:00Z]
      iex> Core.Ingest.Conversation.SentText.place(["Nov 3 10:42 AM", "11:05 AM", "Today 9:15 AM", "huh"], at, "Asia/Karachi")
      [~U[2026-11-03 05:42:00.000000Z], ~U[2026-11-03 06:05:00.000000Z], ~U[2026-11-11 04:15:00.000000Z], ~U[2026-11-11 10:00:00.000000Z]]
  """
  @spec place([String.t() | nil], DateTime.t(), String.t()) :: [DateTime.t()]
  def place(texts, %DateTime{} = captured_at, zone) do
    captured_at = DateTime.truncate(captured_at, :microsecond) |> with_usec()
    today = local(captured_at, zone) |> DateTime.to_date()

    {placed, _day, _last} =
      Enum.reduce(texts, {[], nil, nil}, fn text, {acc, day, last} ->
        {at, day} = at(read(text, today), day || today, day, {zone, captured_at})
        at = after_last(at, last)
        {[at | acc], day, at}
      end)

    Enum.reverse(placed)
  end

  # Where a reading lands, and the day it carries forward.
  defp at({:instant, at}, _day, _last_day, {zone, _captured}),
    do: {with_usec(at), local(at, zone) |> DateTime.to_date()}

  defp at({:at, date, time}, _day, _last_day, {zone, captured}),
    do: {in_zone(date, time, zone, captured), date}

  defp at({:time, time}, day, _last_day, {zone, captured}),
    do: {in_zone(day, time, zone, captured), day}

  defp at({:day, date}, _day, _last_day, {zone, captured}),
    do: {in_zone(date, ~T[00:00:00], zone, captured), date}

  defp at(:now, _day, last_day, {_zone, captured}), do: {captured, last_day}

  # Rows read to the same minute keep their order.
  defp after_last(at, nil), do: at

  defp after_last(at, last) do
    if DateTime.compare(at, last) != :gt and same_minute?(at, last),
      do: DateTime.add(last, 1, :microsecond),
      else: at
  end

  @doc """
  One text read: `{:instant, at}` (an ISO 8601 time), `{:at, date, time}`,
  `{:time, time}`, `{:day, date}` or `:now` (unreadable, or "just now"),
  with `today` the customer's day.

      iex> Core.Ingest.Conversation.SentText.read("Yesterday 4:01 PM", ~D[2026-11-11])
      {:at, ~D[2026-11-10], ~T[16:01:00]}
      iex> Core.Ingest.Conversation.SentText.read("Mon", ~D[2026-11-11])
      {:day, ~D[2026-11-09]}
      iex> Core.Ingest.Conversation.SentText.read("Dec 30", ~D[2026-11-11])
      {:day, ~D[2025-12-30]}
  """
  @spec read(String.t() | nil, Date.t()) ::
          {:instant, DateTime.t()}
          | {:at, Date.t(), Time.t()}
          | {:time, Time.t()}
          | {:day, Date.t()}
          | :now
  def read(nil, _today), do: :now

  def read(text, today) when is_binary(text) do
    case DateTime.from_iso8601(String.trim(text)) do
      {:ok, at, _offset} -> {:instant, DateTime.shift_zone!(at, "Etc/UTC")}
      _not_iso -> words(text, today)
    end
  end

  def read(_other, _today), do: :now

  defp words(text, today) do
    clean =
      text
      |> String.downcase()
      |> String.replace(~r/[,•·]|\bat\b/u, " ")
      |> String.split()
      |> Enum.join(" ")

    {day_part, time} = split_time(clean)

    case {day(day_part, today), time} do
      {:error, _time} -> :now
      {:now, _time} -> :now
      {nil, nil} -> :now
      {nil, time} -> {:time, time}
      {date, nil} -> {:day, date}
      {date, time} -> {:at, date, time}
    end
  end

  defp split_time(text) do
    case Regex.run(~r/^(.*?)\s*(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?$/, text) do
      [_all, rest, h, m | meridiem] ->
        {String.trim(rest),
         time(String.to_integer(h), String.to_integer(m), List.first(meridiem))}

      nil ->
        {text, nil}
    end
  end

  defp time(h, m, meridiem) do
    h =
      case meridiem do
        nil -> h
        "" -> h
        "am" <> _ -> rem(h, 12)
        "a.m." -> rem(h, 12)
        _pm -> rem(h, 12) + 12
      end

    case Time.new(h, m, 0) do
      {:ok, t} -> t
      _bad -> nil
    end
  end

  defp day("", _today), do: nil
  defp day("today", today), do: today
  defp day("yesterday", today), do: Date.add(today, -1)
  defp day("just now", _today), do: :now
  defp day("now", _today), do: :now

  defp day(text, today) do
    weekday = if text =~ ~r/^[a-z]+$/, do: Enum.find_index(@days, &String.starts_with?(text, &1))

    cond do
      weekday ->
        last_weekday(today, weekday + 1)

      match = Regex.run(~r/^([a-z]{3,9})\.?\s+(\d{1,2})(?:\s+(\d{4}))?$/, text) ->
        [_all, month, d | year] = match
        date(month, d, List.first(year), today)

      match = Regex.run(~r/^(\d{1,2})\s+([a-z]{3,9})\.?(?:\s+(\d{4}))?$/, text) ->
        [_all, d, month | year] = match
        date(month, d, List.first(year), today)

      true ->
        :error
    end
  end

  # The most recent such weekday before today (LinkedIn names the last week's).
  defp last_weekday(today, wanted) do
    back = rem(Date.day_of_week(today) - wanted + 7, 7)
    Date.add(today, if(back == 0, do: -7, else: -back))
  end

  defp date(month, d, year, today) do
    with m when not is_nil(m) <- Enum.find_index(@months, &String.starts_with?(month, &1)),
         {:ok, date} <- Date.new(year_of(year, today), m + 1, String.to_integer(d)) do
      if is_nil(year) and Date.compare(date, today) == :gt,
        do: %{date | year: date.year - 1},
        else: date
    else
      _bad -> :error
    end
  end

  defp year_of(nil, today), do: today.year
  defp year_of("", today), do: today.year
  defp year_of(year, _today), do: String.to_integer(year)

  defp in_zone(%Date{} = date, %Time{} = time, zone, captured_at) do
    case DateTime.new(date, time, zone) do
      {:ok, at} -> utc(at)
      {:gap, _before, at} -> utc(at)
      {:ambiguous, at, _later} -> utc(at)
      {:error, _reason} -> captured_at
    end
  end

  defp utc(at), do: at |> DateTime.shift_zone!("Etc/UTC") |> with_usec()

  defp with_usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _unknown -> at
    end
  end

  defp same_minute?(a, b), do: abs(DateTime.diff(a, b, :second)) < 60
end
