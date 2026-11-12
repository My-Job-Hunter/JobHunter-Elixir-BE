defmodule Utils.SafeUrlTest do
  use ExUnit.Case, async: true

  alias Utils.SafeUrl

  doctest SafeUrl

  test "only absolute http and https links with a host pass" do
    for good <- ["http://a.io", "https://jobs.example.com/x?y=1", "HTTPS://Example.com"] do
      assert SafeUrl.safe?(good), good
    end

    for bad <- [
          "javascript:alert(1)",
          "vbscript:x",
          "data:text/html,<b>",
          "blob:https://a.io/x",
          "ftp://a.io",
          "//a.io",
          "a.io",
          "",
          nil,
          42
        ] do
      refute SafeUrl.safe?(bad), inspect(bad)
    end
  end
end
