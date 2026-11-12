defmodule Core.Markdown do
  @moduledoc """
  Markdown as a screen shows it (AQ-07 §11.4: a version's `body_html`):
  rendered by `earmark`, then **sanitised** by `html_sanitize_ex`'s basic
  set (P5's), so a body can carry emphasis, lists and links but never a
  script, a style or an event handler. Pure; computed on read, never
  stored.
  """

  @doc ~S"""
  The HTML of a markdown text; `""` for none.

      iex> Core.Markdown.to_html("**Rate** is *45*")
      "<p>\n<strong>Rate</strong> is <em>45</em></p>\n"
      iex> Core.Markdown.to_html("<script>alert(1)</script>hi") =~ "script"
      false
  """
  @spec to_html(String.t() | nil) :: String.t()
  def to_html(nil), do: ""
  def to_html(""), do: ""

  def to_html(markdown) when is_binary(markdown) do
    case Earmark.as_html(markdown, escape: true, smartypants: false, compact_output: false) do
      {:ok, html, _messages} -> HtmlSanitizeEx.basic_html(html)
      {:error, html, _messages} -> HtmlSanitizeEx.basic_html(html)
    end
  end
end
