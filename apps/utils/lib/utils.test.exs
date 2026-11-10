defmodule UtilsTest do
  use ExUnit.Case, async: true

  doctest Utils

  test "only nil and whitespace strings are blank" do
    assert Utils.blank?(nil)
    assert Utils.blank?("")
    assert Utils.blank?(" \t\n ")

    refute Utils.blank?("a")
    refute Utils.blank?(0)
    refute Utils.blank?(false)
    refute Utils.blank?([])
  end

  test "presence trims, and turns blank into nil" do
    assert Utils.presence(nil) == nil
    assert Utils.presence("") == nil
    assert Utils.presence("  Upwork  ") == "Upwork"
  end
end
