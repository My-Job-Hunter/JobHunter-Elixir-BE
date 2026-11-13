defmodule Core.Inbound.Address do
  @moduledoc """
  An email channel's forwarding address (AQ-09 §6.1, QP9-5), **pure**:
  built from a template holding `{token}` (`config :core, :inbound,
  address:`) and the channel's token, and read back the same way. Only an
  address of the template's shape names a token; the token's ten
  characters are `a–z` and `2–9`, any case.
  """

  @doc ~S"""
  The address for `token`.

      iex> Core.Inbound.Address.build("in+{token}@inbound.autoqare.local", "k3m9q2x7wa")
      "in+k3m9q2x7wa@inbound.autoqare.local"
  """
  @spec build(String.t(), String.t()) :: String.t()
  def build(template, token), do: String.replace(template, "{token}", token)

  @doc ~S"""
  The token an address names, or `nil` when it is not the template's shape.
  A display name (`Tanweer <in+…@…>`) and case are ignored.

      iex> Core.Inbound.Address.token("in+{token}@inbound.autoqare.local", "IN+K3M9Q2X7WA@Inbound.Autoqare.Local")
      "k3m9q2x7wa"
      iex> Core.Inbound.Address.token("in+{token}@inbound.autoqare.local", "Forwarding <in+k3m9q2x7wa@inbound.autoqare.local>")
      "k3m9q2x7wa"
      iex> Core.Inbound.Address.token("abc123+{token}@inbound.postmarkapp.com", "abc123+k3m9q2x7wa@inbound.postmarkapp.com")
      "k3m9q2x7wa"
      iex> Core.Inbound.Address.token("in+{token}@inbound.autoqare.local", "in+k3m9q2x7wa@elsewhere.example")
      nil
      iex> Core.Inbound.Address.token("in+{token}@inbound.autoqare.local", nil)
      nil
  """
  @spec token(String.t(), String.t() | nil) :: String.t() | nil
  def token(template, address) when is_binary(address) do
    [before, rest] = String.split(template, "{token}", parts: 2)

    pattern =
      Regex.compile!(
        "^" <> Regex.escape(before) <> "([a-z2-9]{10})" <> Regex.escape(rest) <> "$",
        "i"
      )

    case Regex.run(pattern, bare(address), capture: :all_but_first) do
      [token] -> String.downcase(token)
      nil -> nil
    end
  end

  def token(_template, _address), do: nil

  @doc ~S"""
  The bare address of a header's value, lowercased.

      iex> Core.Inbound.Address.bare(" Tanweer <Tanweer@Example.com> ")
      "tanweer@example.com"
  """
  @spec bare(String.t()) :: String.t()
  def bare(value) do
    case Regex.run(~r/<([^<>]+)>/, value, capture: :all_but_first) do
      [inside] -> inside
      nil -> value
    end
    |> String.trim()
    |> String.downcase()
  end
end
