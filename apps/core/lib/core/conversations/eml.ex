defmodule Core.Conversations.Eml do
  @moduledoc """
  An uploaded email read (AQ-06 §7.1, QP6-6), **pure**: the bytes of one
  RFC 5322 message in, what threading and matching need out —

  `%{message_id, in_reply_to, references, from: {name, address}, to:
  [{name, address}], cc, subject, sent_at, text, html, attachments:
  [%{filename, content_type, bytes}], calendar}`.

  The `mail` package parses the headers and the multipart; bodies are
  decoded (base64, quoted-printable) and turned into UTF-8 from their
  charset; **the HTML is sanitised** (`html_sanitize_ex`, P5's) and a text
  body is read from it when the email has none. A part with a filename (or
  `Content-Disposition: attachment`) is an attachment, whose bytes
  `Core.Media` sniffs before it is kept. Anything it cannot read is
  `{:error, :unreadable}`.

  `calendar` (AQ-09 §9) is the text of the first invitation part — a
  `text/calendar` or `application/ics` part, or a `.ics` file — or `nil`;
  `Core.Meetings.Invite` reads it.
  """

  alias Mail.Parsers.RFC2822

  @doc "Reads one email's bytes."
  @spec parse(binary()) :: {:ok, map()} | {:error, :unreadable}
  def parse(bytes) when is_binary(bytes) do
    bytes
    |> utf8()
    |> String.replace(~r/\r?\n/, "\r\n")
    |> RFC2822.parse(charset_handler: &charset/2)
    |> read()
  rescue
    _unreadable -> {:error, :unreadable}
  end

  defp read(%Mail.Message{headers: headers} = mail) do
    if headers == %{} or is_nil(headers["from"]) do
      {:error, :unreadable}
    else
      parts = flatten(mail)
      {text, html} = bodies(parts)

      {:ok,
       %{
         message_id: id(headers["message-id"]),
         in_reply_to: id(headers["in-reply-to"]),
         references: ids(headers["references"]),
         from: address(headers["from"]),
         to: addresses(headers["to"]),
         cc: addresses(headers["cc"]),
         subject: text_header(headers["subject"]),
         sent_at: date(headers["date"]),
         text: text,
         html: html,
         attachments: attachments(parts),
         calendar: calendar(parts)
       }}
    end
  end

  # ── Headers ─────────────────────────────────────────────────────────────────

  @doc ~S"""
  A `Message-ID` without its angle brackets.

      iex> Core.Conversations.Eml.id(" <abc@mail.example> ")
      "abc@mail.example"
      iex> Core.Conversations.Eml.id(nil)
      nil
  """
  @spec id(term()) :: String.t() | nil
  def id(value) when is_binary(value) do
    case ids(value) do
      [first | _rest] -> first
      [] -> nil
    end
  end

  def id(_value), do: nil

  @doc ~S"""
  The ids of a `References` header, in order.

      iex> Core.Conversations.Eml.ids("<a@x> <b@x>\r\n <c@x>")
      ["a@x", "b@x", "c@x"]
  """
  @spec ids(term()) :: [String.t()]
  def ids(value) when is_binary(value) do
    case Regex.scan(~r/<([^<>\s]+)>/, value, capture: :all_but_first) do
      [] -> value |> String.split() |> Enum.reject(&(&1 == ""))
      found -> List.flatten(found)
    end
  end

  def ids(_value), do: []

  defp address({name, address}), do: {blank(name), String.downcase(String.trim(address))}
  defp address(address) when is_binary(address), do: {nil, String.downcase(String.trim(address))}
  defp address(_other), do: {nil, nil}

  defp addresses(list) when is_list(list),
    do: list |> Enum.map(&address/1) |> Enum.reject(&is_nil(elem(&1, 1)))

  defp addresses(nil), do: []
  defp addresses(one), do: addresses([one])

  defp text_header(value) when is_binary(value), do: blank(value)
  defp text_header(_value), do: nil

  defp date(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp date(_bad), do: nil

  # ── Bodies and attachments ──────────────────────────────────────────────────

  # Every leaf part, in order (a single-part email is its own leaf).
  defp flatten(%Mail.Message{multipart: true, parts: parts}), do: Enum.flat_map(parts, &flatten/1)
  defp flatten(%Mail.Message{} = leaf), do: [leaf]

  defp bodies(parts) do
    texts = for p <- parts, not attachment?(p), type(p) == "text/plain", do: body(p)
    htmls = for p <- parts, not attachment?(p), type(p) == "text/html", do: body(p)

    html = htmls |> Enum.join("\n") |> blank() |> sanitise()
    text = texts |> Enum.join("\n\n") |> blank() || (html && plain(html))
    {text && String.trim(text), html}
  end

  defp attachments(parts) do
    for p <- parts, attachment?(p), is_binary(p.body), byte_size(p.body) > 0 do
      %{filename: filename(p), content_type: type(p), bytes: p.body}
    end
  end

  defp calendar(parts) do
    Enum.find_value(parts, fn p ->
      name = filename(p) || ""

      if (type(p) in ["text/calendar", "application/ics"] or
            String.ends_with?(String.downcase(name), ".ics")) and is_binary(p.body) and
           p.body != "",
         do: String.replace_invalid(p.body, "?")
    end)
  end

  defp attachment?(part),
    do: Mail.Message.is_attachment?(part, :all) or not is_nil(filename(part))

  defp filename(part) do
    disposition = List.wrap(Mail.Message.get_header(part, "content-disposition"))
    content_type = List.wrap(part.headers["content-type"])

    (Mail.Proplist.get(disposition, "filename") || Mail.Proplist.get(content_type, "name"))
    |> case do
      name when is_binary(name) -> name |> String.trim() |> String.slice(0, 200) |> blank()
      _none -> nil
    end
  rescue
    _odd -> nil
  end

  defp type(part) do
    case part.headers["content-type"] do
      [type | _params] when is_binary(type) -> String.downcase(type)
      type when is_binary(type) -> String.downcase(type)
      _none -> "text/plain"
    end
  end

  defp body(part) when is_binary(part.body),
    do: part.body |> String.replace_invalid("?") |> String.replace(~r/\r\n?/, "\n")

  defp body(_part), do: ""

  defp sanitise(nil), do: nil
  defp sanitise(html), do: html |> HtmlSanitizeEx.basic_html() |> blank()

  defp plain(html) do
    html
    |> String.replace(~r/<br\s*\/?>|<\/p>|<\/div>/i, "\n")
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> blank()
  end

  # ── Charsets ────────────────────────────────────────────────────────────────

  # Bytes that are not UTF-8 (an 8-bit header) are read as Latin-1, so the
  # parser never meets an invalid sequence.
  defp utf8(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: :unicode.characters_to_binary(bytes, :latin1)
  end

  @latin ~w(iso-8859-1 iso8859-1 latin1 latin-1 windows-1252 cp1252 us-ascii ascii)

  defp charset(charset, bin) when is_binary(bin) do
    name = String.downcase(charset)

    cond do
      name in ["utf-8", "utf8"] -> bin
      name in @latin and not String.valid?(bin) -> :unicode.characters_to_binary(bin, :latin1)
      true -> bin
    end
  end

  defp charset(_charset, other), do: other

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _text -> value
    end
  end
end
