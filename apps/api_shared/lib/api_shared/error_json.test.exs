defmodule ApiShared.ErrorJSONTest do
  @moduledoc """
  The error contract, asserted directly.

  Copied from AutoCare, where the generated version of this file asserted
  Phoenix's default shape and never ran: it was named `_test.exs`, which
  `test_pattern: "*.test.exs"` does not match. `Core.ConventionsTest` catches
  that class of file.
  """

  use ExUnit.Case, async: true

  test "renders 404 in the house shape, with a stable code" do
    assert ApiShared.ErrorJSON.render("404.json", %{}) == %{
             error: %{code: "not_found", message: "We could not find that.", details: %{}}
           }
  end

  test "renders 401" do
    assert %{error: %{code: "unauthenticated"}} = ApiShared.ErrorJSON.render("401.json", %{})
  end

  test "renders 500 without leaking anything about the failure" do
    assert %{error: %{code: "internal_error", details: %{}}} =
             ApiShared.ErrorJSON.render("500.json", %{})
  end

  test "falls back to the status name for anything Phoenix raises itself" do
    assert %{error: %{code: "Unprocessable Content"}} =
             ApiShared.ErrorJSON.render("422.json", %{})
  end

  test "the code is the contract, so it is a string clients can match on" do
    for template <- ["404.json", "401.json", "500.json"] do
      assert %{error: %{code: code}} = ApiShared.ErrorJSON.render(template, %{})
      assert is_binary(code)
    end
  end
end
