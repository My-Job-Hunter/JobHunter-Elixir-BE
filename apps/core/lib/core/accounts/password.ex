defmodule Core.Accounts.Password do
  @moduledoc """
  The password rule (AQ-01 QP1-6): **at least ten characters, no other
  rules**, and not one of the worst passwords. Length is what matters;
  composition rules produce `Password1!`. `check/2` is pure.

  **On a dev server the worst-list is skipped** (`config :core,
  dev_worst_passwords: true`, dev.exs only; the user's words of
  2026-11-11, PLAN §A): the cast signs in with a shared test password
  that is on the list. Test and production keep the whole rule.
  """

  @min_length 10
  # bcrypt reads 72 bytes and silently ignores the rest.
  @max_bytes 72

  # The short worst-list: what people type when told "at least ten".
  @worst ~w(
    1234567890 12345678910 0123456789 qwertyuiop password1 password12 password123
    passw0rd12 1q2w3e4r5t 1234qwerty qwerty1234 iloveyou12 adminadmin administrator
    letmein123 welcome123 football12 monkey1234 abcdefghij aaaaaaaaaa 1111111111
    0000000000 changeme12 autoqare1 autoqare123
  )

  @doc "How long a password must be. Public so a screen can say it."
  @spec min_length() :: pos_integer()
  def min_length, do: @min_length

  @doc "The worst-list, for the test that checks it is checked."
  @spec worst() :: [String.t()]
  def worst, do: @worst

  @doc """
  `:ok`, or `{:error, :password_too_weak}`.

      iex> Core.Accounts.Password.check("correct horse battery")
      :ok
      iex> Core.Accounts.Password.check("short")
      {:error, :password_too_weak}
  """
  @spec check(String.t() | nil) :: :ok | {:error, :password_too_weak}
  def check(password),
    do: check(password, allow_worst: Application.get_env(:core, :dev_worst_passwords, false))

  @doc """
  The rule itself, with `allow_worst: true` skipping only the worst-list
  (a dev server's, see the moduledoc). Length and bytes always hold.

      iex> Core.Accounts.Password.check("password123", allow_worst: false)
      {:error, :password_too_weak}
      iex> Core.Accounts.Password.check("password123", allow_worst: true)
      :ok
      iex> Core.Accounts.Password.check("short", allow_worst: true)
      {:error, :password_too_weak}
  """
  @spec check(String.t() | nil, keyword()) :: :ok | {:error, :password_too_weak}
  def check(password, opts) when is_binary(password) do
    cond do
      String.length(password) < @min_length ->
        {:error, :password_too_weak}

      byte_size(password) > @max_bytes ->
        {:error, :password_too_weak}

      !opts[:allow_worst] and String.downcase(password) in @worst ->
        {:error, :password_too_weak}

      true ->
        :ok
    end
  end

  def check(_not_a_string, _opts), do: {:error, :password_too_weak}
end
