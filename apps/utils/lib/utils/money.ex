defmodule Utils.Money do
  @moduledoc """
  Money as people write it (AQ-04B QP4b-18: the CSV's money "as written,
  with its currency, never summed or converted"), **pure**. A minor unit is
  ISO 4217's exponent (CONVENTIONS §3): 2 for most, 0 for JPY and its kind,
  3 for KWD and its kind — the same table as the frontend's `minorDigits`.
  """

  @zero ~w(BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX UYI VND VUV XAF XOF XPF)
  @three ~w(BHD IQD JOD KWD LYD OMR TND)

  @doc ~S"""
  How many minor digits a currency has.

      iex> Enum.map(~w(USD JPY KWD PKR), &Utils.Money.minor_digits/1)
      [2, 0, 3, 2]
  """
  @spec minor_digits(String.t() | nil) :: 0 | 2 | 3
  def minor_digits(currency) do
    code = currency |> to_string() |> String.upcase()

    cond do
      code in @zero -> 0
      code in @three -> 3
      true -> 2
    end
  end

  @doc ~S"""
  An amount in minor units as written: grouped by thousands, the fraction
  shown only when it is not zero.

      iex> Utils.Money.amount(400_000_00, "PKR")
      "400,000"
      iex> Utils.Money.amount(1_234_550, "USD")
      "12,345.50"
      iex> Utils.Money.amount(5000, "JPY")
      "5,000"
      iex> Utils.Money.amount(1500, "KWD")
      "1.500"
  """
  @spec amount(integer(), String.t()) :: String.t()
  def amount(minor, currency) when is_integer(minor) do
    digits = minor_digits(currency)
    factor = Integer.pow(10, digits)
    whole = div(abs(minor), factor)
    fraction = rem(abs(minor), factor)
    sign = if minor < 0, do: "-", else: ""
    grouped = group(Integer.to_string(whole))

    if fraction == 0,
      do: sign <> grouped,
      else: sign <> grouped <> "." <> String.pad_leading(Integer.to_string(fraction), digits, "0")
  end

  defp group(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  @doc ~S"""
  A range of money as one line: "PKR 300,000–400,000 / month"; one amount
  when both ends agree; "Undisclosed"; the posting's own words when it has
  no amount; `""` for nothing. `money` is P3's shape (`min_minor`,
  `max_minor`, `currency`, `period`, `is_estimate`, `is_undisclosed`,
  `text`).

      iex> Utils.Money.line(%{min_minor: 30_000_000, max_minor: 40_000_000, currency: "PKR", period: :month})
      "PKR 300,000–400,000 / month"
      iex> Utils.Money.line(%{min_minor: 500_000, max_minor: nil, currency: "USD", period: "year", is_estimate: true})
      "USD 5,000 / year (estimate)"
      iex> Utils.Money.line(%{min_minor: nil, max_minor: nil, is_undisclosed: true})
      "Undisclosed"
      iex> Utils.Money.line(nil)
      ""
  """
  @spec line(map() | nil) :: String.t()
  def line(nil), do: ""

  def line(money) do
    min = Map.get(money, :min_minor)
    max = Map.get(money, :max_minor)
    currency = Map.get(money, :currency)

    cond do
      (min || max) && currency -> amounts(money, min, max, currency)
      Map.get(money, :is_undisclosed) -> "Undisclosed"
      true -> Map.get(money, :text) || ""
    end
  end

  defp amounts(money, min, max, currency) do
    period = Map.get(money, :period)
    per = if period, do: " / #{period}", else: ""
    estimate = if Map.get(money, :is_estimate), do: " (estimate)", else: ""
    "#{currency} #{range(min, max, currency)}#{per}#{estimate}"
  end

  defp range(a, b, currency) when is_integer(a) and is_integer(b) and a != b,
    do: amount(a, currency) <> "–" <> amount(b, currency)

  defp range(a, _b, currency) when is_integer(a), do: amount(a, currency)
  defp range(nil, b, currency), do: amount(b, currency)
end
