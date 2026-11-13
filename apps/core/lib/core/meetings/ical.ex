defmodule Core.Meetings.Ical do
  @moduledoc """
  A small iCalendar reader (RFC 5545), **pure**: the text of an `.ics`
  in, its components out — each `%{name, props, components}`, a property
  `%{name, params, value}` with the name and the parameters' names upper
  case and the value as written (`text/1` unescapes a TEXT value).

  It unfolds lines (a line starting with a space or a tab continues the
  one before), splits a property at the first `:` outside a quoted
  parameter, reads `;`-separated parameters (quoted or not), and nests
  `BEGIN:`/`END:` blocks. A line it can't read is skipped; an `END`
  without its `BEGIN` closes nothing. What a calendar *means* (an
  invitation's times and link) is `Core.Meetings.Invite`'s.
  """

  @type prop :: %{name: String.t(), params: %{String.t() => String.t()}, value: String.t()}
  @type component :: %{name: String.t(), props: [prop()], components: [component()]}

  @doc ~S"""
  The top-level components of `text` (usually one `VCALENDAR`).

      iex> [cal] = Core.Meetings.Ical.parse("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nSUMMARY:Tech\r\n nical interview\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
      iex> {cal.name, Core.Meetings.Ical.value(cal, "METHOD")}
      {"VCALENDAR", "REQUEST"}
      iex> [event] = cal.components
      iex> Core.Meetings.Ical.value(event, "SUMMARY")
      "Technical interview"
  """
  @spec parse(String.t()) :: [component()]
  def parse(text) when is_binary(text) do
    text
    |> unfold()
    |> Enum.map(&line/1)
    |> Enum.reject(&is_nil/1)
    |> nest()
  end

  @doc ~S"""
  The lines of `text`, unfolded (CRLF or LF, then a space or a tab).

      iex> Core.Meetings.Ical.unfold("DESCRIPTION:Join\r\n  here\nUID:1\n\tx\r\n")
      ["DESCRIPTION:Join here", "UID:1x"]
  """
  @spec unfold(String.t()) :: [String.t()]
  def unfold(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc ~S"""
  One content line as a property, or `nil` when it has no `:`.

      iex> Core.Meetings.Ical.line(~s|DTSTART;TZID="Asia/Karachi";VALUE=DATE-TIME:20261118T140000|)
      %{name: "DTSTART", params: %{"TZID" => "Asia/Karachi", "VALUE" => "DATE-TIME"}, value: "20261118T140000"}
      iex> Core.Meetings.Ical.line("ORGANIZER;CN=\"Chen, Mei\":mailto:mei.chen@juniperedge.example")
      %{name: "ORGANIZER", params: %{"CN" => "Chen, Mei"}, value: "mailto:mei.chen@juniperedge.example"}
      iex> Core.Meetings.Ical.line("no colon here")
      nil
  """
  @spec line(String.t()) :: prop() | nil
  def line(line) do
    case split_value(line, "", false) do
      {head, value} ->
        [name | params] = split_params(head, [], "", false)
        %{name: String.upcase(String.trim(name)), params: params(params), value: value}

      nil ->
        nil
    end
  end

  # The first `:` outside double quotes ends the name and parameters.
  defp split_value(<<>>, _acc, _quoted), do: nil

  defp split_value(<<?", rest::binary>>, acc, quoted),
    do: split_value(rest, acc <> "\"", not quoted)

  defp split_value(<<?:, rest::binary>>, acc, false), do: {acc, rest}

  defp split_value(<<c::utf8, rest::binary>>, acc, quoted),
    do: split_value(rest, acc <> <<c::utf8>>, quoted)

  defp split_value(<<_byte, rest::binary>>, acc, quoted), do: split_value(rest, acc, quoted)

  defp split_params(<<>>, parts, acc, _quoted), do: Enum.reverse([acc | parts])

  defp split_params(<<?", rest::binary>>, parts, acc, quoted),
    do: split_params(rest, parts, acc <> "\"", not quoted)

  defp split_params(<<?;, rest::binary>>, parts, acc, false),
    do: split_params(rest, [acc | parts], "", false)

  defp split_params(<<c::utf8, rest::binary>>, parts, acc, quoted),
    do: split_params(rest, parts, acc <> <<c::utf8>>, quoted)

  defp split_params(<<_byte, rest::binary>>, parts, acc, quoted),
    do: split_params(rest, parts, acc, quoted)

  defp params(parts) do
    for part <- parts, [key, value] <- [String.split(part, "=", parts: 2)], into: %{} do
      {String.upcase(String.trim(key)), value |> String.trim() |> String.trim("\"")}
    end
  end

  # BEGIN/END into a tree; properties belong to the innermost open block.
  defp nest(props) do
    {done, _stack} =
      Enum.reduce(props, {[], []}, fn prop, {done, stack} ->
        case {prop.name, stack} do
          {"BEGIN", _stack} ->
            {done,
             [%{name: String.upcase(String.trim(prop.value)), props: [], components: []} | stack]}

          {"END", [open]} ->
            {[finish(open) | done], []}

          {"END", [open, parent | rest]} ->
            {done, [%{parent | components: [finish(open) | parent.components]} | rest]}

          {"END", []} ->
            {done, []}

          {_name, [open | rest]} ->
            {done, [%{open | props: [prop | open.props]} | rest]}

          {_name, []} ->
            {done, []}
        end
      end)

    Enum.reverse(done)
  end

  defp finish(c), do: %{c | props: Enum.reverse(c.props), components: Enum.reverse(c.components)}

  @doc "A component's first property called `name`, or `nil`."
  @spec prop(component(), String.t()) :: prop() | nil
  def prop(%{props: props}, name), do: Enum.find(props, &(&1.name == name))

  @doc "A component's first `name` value, unescaped as TEXT, or `nil`."
  @spec value(component(), String.t()) :: String.t() | nil
  def value(component, name) do
    case prop(component, name) do
      %{value: value} -> text(value)
      nil -> nil
    end
  end

  @doc "The sub-components called `name`."
  @spec components(component(), String.t()) :: [component()]
  def components(%{components: cs}, name), do: Enum.filter(cs, &(&1.name == name))

  @doc ~S"""
  A TEXT value unescaped (RFC 5545 §3.3.11).

      iex> Core.Meetings.Ical.text("Line one\\nLine two\\, and \; more\\\\")
      "Line one\nLine two, and ; more\\"
  """
  @spec text(String.t()) :: String.t()
  def text(value) do
    Regex.replace(~r/\\([nN,;\\])/, value, fn
      _all, "n" -> "\n"
      _all, "N" -> "\n"
      _all, other -> other
    end)
  end
end
