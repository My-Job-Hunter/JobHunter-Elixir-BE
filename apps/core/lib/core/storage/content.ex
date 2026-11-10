defmodule Core.Storage.Content do
  @moduledoc """
  What a file actually is, read from its bytes (JH-01 QP1-3: *bytes sniffed*).

  > **The allowlist is checked against the bytes, not the header.** A
  > client-supplied `Content-Type` is a claim.

  Magic numbers for the binary formats; a DOCX is a ZIP whose first entry
  names `[Content_Types].xml` or `word/`; a text file is valid UTF-8 with no
  NUL byte that matches nothing else. SVG is off the list for the reason HTML
  is: it executes.
  """

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  @doc "What these bytes are, or `nil` for anything not on the allowlist."
  @spec detect(binary()) :: String.t() | nil
  def detect(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  def detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  def detect(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  def detect(<<"%PDF-", _rest::binary>>), do: "application/pdf"

  # A ZIP local file header; the first entry's name follows at offset 30.
  def detect(<<"PK", 3, 4, _fields::binary-size(26), rest::binary>>) do
    head = binary_part(rest, 0, min(byte_size(rest), 64))

    if String.contains?(head, ["[Content_Types].xml", "word/", "_rels/"]), do: @docx, else: nil
  end

  def detect(bytes) when is_binary(bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>), do: "text/plain", else: nil
  end

  @doc """
  Whether the bytes are what the row said they would be. Markdown is text
  to the bytes, so a row declared `text/markdown` accepts what reads as
  `text/plain`.
  """
  @spec matches?(binary(), String.t()) :: boolean()
  def matches?(bytes, declared) do
    case detect(bytes) do
      nil -> false
      ^declared -> true
      "text/plain" -> declared == "text/markdown"
      _other -> false
    end
  end
end
