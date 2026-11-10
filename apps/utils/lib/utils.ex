defmodule Utils do
  @moduledoc """
  Pure helpers, and the umbrella's dependency hub.

  **Pure in its code**: nothing here touches the database, the clock, the
  network or the process dictionary, and nothing here names another app — it
  is the leaf every app depends on (`Core.ConventionsTest` holds that). The
  third-party dependencies live in this app's `mix.exs` so the apps above it
  share one version of each; this module names none of them.

  Its helpers arrive with the phases that need them (PLAN §15.1): `JobKey`
  (a job URL to its canonical key, P3), `Units`, `SafeUrl`.
  """

  @doc """
  Whether a value carries nothing: `nil`, or a string of only whitespace.

      iex> Utils.blank?(nil)
      true
      iex> Utils.blank?("  \\n")
      true
      iex> Utils.blank?("Elixir")
      false
  """
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: false

  @doc """
  The trimmed string, or `nil` when it is blank — what a form field means.

      iex> Utils.presence("  Lahore ")
      "Lahore"
      iex> Utils.presence("   ")
      nil
  """
  @spec presence(String.t() | nil) :: String.t() | nil
  def presence(nil), do: nil

  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
