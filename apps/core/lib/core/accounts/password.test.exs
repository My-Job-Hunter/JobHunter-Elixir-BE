defmodule Core.Accounts.PasswordTest do
  use ExUnit.Case, async: true

  alias Core.Accounts.Password

  doctest Password

  test "ten characters is enough, nine is not, and composition does not matter (QP1-6)" do
    assert Password.check("zxqvbnmkpl") == :ok
    assert Password.check("zxqvbnmkp") == {:error, :password_too_weak}
    assert Password.check("ten letters no digits") == :ok
  end

  test "the worst-list is refused whatever the case" do
    for worst <- Password.worst() do
      assert Password.check(worst) == {:error, :password_too_weak}, worst
      assert Password.check(String.upcase(worst)) == {:error, :password_too_weak}
    end
  end

  test "longer than bcrypt reads is refused rather than silently truncated" do
    assert Password.check(String.duplicate("a", 73)) == {:error, :password_too_weak}
    assert Password.check(String.duplicate("a", 72)) == :ok
  end

  test "a dev server skips only the worst-list; test and production keep it" do
    refute Application.get_env(:core, :dev_worst_passwords, false)
    assert Password.check("password123") == {:error, :password_too_weak}
    assert Password.check("password123", allow_worst: true) == :ok
    assert Password.check("password12", []) == {:error, :password_too_weak}
    assert Password.check("short", allow_worst: true) == {:error, :password_too_weak}
  end

  test "not a string is too weak" do
    assert Password.check(nil) == {:error, :password_too_weak}
    assert Password.check(12_345_678_901) == {:error, :password_too_weak}
  end
end
