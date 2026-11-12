defmodule Core.Accounts.Device do
  @moduledoc """
  The device line on the account page (AQ-01 §7.1: "Chrome on macOS ·
  signed in 2 h ago"), from the user agent a sign-in stored in the token's
  claims (`dev.agent`). Pure, and deliberately coarse: a browser family and
  an OS family are what a person recognises; a version number is noise.
  """

  @browsers [
    {"Edg/", "Edge"},
    {"OPR/", "Opera"},
    {"Firefox/", "Firefox"},
    {"Chrome/", "Chrome"},
    {"CriOS/", "Chrome"},
    {"Safari/", "Safari"},
    {"curl/", "curl"}
  ]

  @systems [
    {"iPhone", "iOS"},
    {"iPad", "iPadOS"},
    {"Android", "Android"},
    {"Windows", "Windows"},
    {"Mac OS X", "macOS"},
    {"Macintosh", "macOS"},
    {"CrOS", "ChromeOS"},
    {"Linux", "Linux"}
  ]

  @doc """
  "Chrome on macOS" from a `dev` claim; `nil` when nothing was recorded.

      iex> Core.Accounts.Device.describe(%{"agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"})
      "Chrome on macOS"
      iex> Core.Accounts.Device.describe(%{"agent" => "curl/8.4.0"})
      "curl"
      iex> Core.Accounts.Device.describe(%{})
      nil
  """
  @spec describe(map() | nil) :: String.t() | nil
  def describe(%{"agent" => agent}) when is_binary(agent) and agent != "" do
    browser = first_match(agent, @browsers)
    system = first_match(agent, @systems)

    case {browser, system} do
      {nil, nil} -> String.slice(agent, 0, 60)
      {browser, nil} -> browser
      {nil, system} -> "a browser on #{system}"
      {browser, system} -> "#{browser} on #{system}"
    end
  end

  def describe(_none), do: nil

  defp first_match(agent, table) do
    Enum.find_value(table, fn {needle, name} -> String.contains?(agent, needle) && name end)
  end
end
