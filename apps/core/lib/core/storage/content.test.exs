defmodule Core.Storage.ContentTest do
  use ExUnit.Case, async: true

  alias Core.Storage.Content

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  test "the allowlist by signature" do
    assert Content.detect(<<0xFF, 0xD8, 0xFF, 0xE0, "JFIF">>) == "image/jpeg"
    assert Content.detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0>>) == "image/png"
    assert Content.detect("RIFF" <> <<1, 2, 3, 4>> <> "WEBPVP8 ") == "image/webp"
    assert Content.detect("%PDF-1.7\n%âãÏÓ") == "application/pdf"

    assert Content.detect("PK" <> <<3, 4>> <> :binary.copy(<<0>>, 26) <> "[Content_Types].xml...") ==
             @docx

    assert Content.detect("# A CV\n\nPlain words.") == "text/plain"
  end

  test "what is not on the list is nil, SVG included" do
    assert Content.detect("<svg xmlns='http://www.w3.org/2000/svg'></svg>") == "text/plain"
    refute Content.matches?("<svg/>", "image/svg+xml")
    assert Content.detect("PK" <> <<3, 4>> <> :binary.copy(<<0>>, 26) <> "evil.exe") == nil
    assert Content.detect(<<0, 1, 2, 3>>) == nil
    assert Content.detect(<<0xFF, 0xFE, 0>>) == nil
  end

  test "the bytes must be what was declared; markdown reads as text" do
    assert Content.matches?("%PDF-1.4", "application/pdf")
    refute Content.matches?("%PDF-1.4", "image/jpeg")
    refute Content.matches?(<<0xFF, 0xD8, 0xFF, 0>>, "application/pdf")
    assert Content.matches?("## heading", "text/markdown")
    assert Content.matches?("## heading", "text/plain")
    refute Content.matches?(<<0, 0>>, "text/plain")
  end
end
