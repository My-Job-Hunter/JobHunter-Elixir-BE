defmodule Core.MarkdownTest do
  @moduledoc "A version's `body_html` (AQ-07 §11.4): markdown rendered, then sanitised."

  use ExUnit.Case, async: true

  doctest Core.Markdown

  test "links and lists survive; scripts, styles and handlers don't" do
    html =
      Core.Markdown.to_html("- one\n- [two](https://example.com)\n\n<img src=x onerror=alert(1)>")

    assert html =~ "<li>"
    assert html =~ ~s(href="https://example.com")
    refute html =~ "onerror"
    assert Core.Markdown.to_html(nil) == ""
  end
end
