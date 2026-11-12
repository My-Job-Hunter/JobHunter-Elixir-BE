defmodule Core.Ingest.Extension.Money do
  @moduledoc """
  Money as a page writes it (AQ-05 §10.1), **pure**: in the currency's
  minor units (ISO 4217's, `Utils.Money.minor_digits/1`), with the currency
  and the period, **never summed or converted**. A text with no amount, no
  currency or (for a salary) no period is no money at all.
  """

  @symbols [
    {"US$", "USD"},
    {"CA$", "CAD"},
    {"A$", "AUD"},
    {"$", "USD"},
    {"£", "GBP"},
    {"€", "EUR"},
    {"₹", "INR"},
    {"Rs", "PKR"},
    {"¥", "JPY"}
  ]
  @codes ~w(USD GBP EUR PKR INR CAD AUD AED JPY CHF SEK NOK DKK PLN)

  @periods [
    {~r{/\s*(yr|year)\b|a year|per year|yearly|annual}i, "year"},
    {~r{/\s*(hr|hour)\b|an hour|per hour|hourly}i, "hour"},
    {~r{/\s*(mo|month)\b|a month|per month|monthly}i, "month"},
    {~r{/\s*(wk|week)\b|a week|per week|weekly}i, "week"},
    {~r{/\s*day\b|a day|per day|daily}i, "day"}
  ]

  @amount ~r/(\d[\d,]*(?:\.\d+)?)(?:\s?([KkMm])(?![A-Za-z]))?/u

  @doc """
  The job's `comp_*` columns from what was said (`text`): `period` and
  `source` as the caller knows them (Upwork: `hour` or `project`,
  `employer`). `%{}` when there is no amount.
  """
  @spec comp(String.t() | nil, String.t(), String.t()) :: map()
  def comp(nil, _period, _source), do: %{}

  def comp(text, period, source) do
    case amounts(text) do
      {currency, [min | _] = amounts} ->
        %{
          "comp_min_minor" => min,
          "comp_max_minor" => List.last(amounts),
          "comp_currency" => currency,
          "comp_period" => period,
          "comp_source" => source,
          "comp_text" => text
        }

      _none ->
        %{}
    end
  end

  @doc """
  A salary as written: `%{min, max, currency, period, text}` in minor units,
  or `nil` when there is no amount, no currency or no period.

      iex> Core.Ingest.Extension.Money.salary("$50/hr")
      %{min: 5000, max: 5000, currency: "USD", period: "hour", text: "$50/hr"}
  """
  @spec salary(String.t() | nil) :: map() | nil
  def salary(nil), do: nil

  def salary(text) do
    period = Enum.find_value(@periods, fn {regex, p} -> Regex.match?(regex, text) && p end)

    case amounts(text) do
      {currency, [min | _] = amounts} when not is_nil(period) ->
        %{min: min, max: List.last(amounts), currency: currency, period: period, text: text}

      _none ->
        nil
    end
  end

  @doc """
  A bid as written: `%{bid_minor, bid_currency, bid_period}` (`hour` for a
  rate, `project` for a sum), or `nil`.

      iex> Core.Ingest.Extension.Money.bid("$45.00/hr")
      %{bid_minor: 4500, bid_currency: "USD", bid_period: "hour"}
      iex> Core.Ingest.Extension.Money.bid("$500.00")
      %{bid_minor: 50000, bid_currency: "USD", bid_period: "project"}
  """
  @spec bid(String.t() | nil) :: map() | nil
  def bid(nil), do: nil

  def bid(text) do
    period = if text =~ ~r{/\s*(hr|hour)\b|hourly|an hour|per hour}i, do: "hour", else: "project"

    case amounts(text) do
      {currency, [amount | _]} -> %{bid_minor: amount, bid_currency: currency, bid_period: period}
      _none -> nil
    end
  end

  @doc """
  What an Upwork client has spent, banded (`upwork_spent_bands`).

      iex> Core.Ingest.Extension.Money.spent_band("$10K+ total spent")
      :"10k_100k"
  """
  @spec spent_band(String.t()) :: atom() | nil
  def spent_band(text) do
    case amounts(text) do
      {currency, [minor | _]} ->
        band(div(minor, Integer.pow(10, Utils.Money.minor_digits(currency))))

      _none ->
        if text =~ ~r/\b0\b|no spend/i, do: :none, else: nil
    end
  end

  defp band(0), do: :none
  defp band(n) when n < 1_000, do: :lt_1k
  defp band(n) when n < 10_000, do: :"1k_10k"
  defp band(n) when n < 100_000, do: :"10k_100k"
  defp band(n) when n < 1_000_000, do: :"100k_1m"
  defp band(_n), do: :gt_1m

  @doc """
  The currency and the first two amounts of a text, in that currency's
  minor units, in order: "$120K/yr - $150K/yr" → `{"USD", [12_000_000,
  15_000_000]}`; `nil` without a currency.
  """
  @spec amounts(String.t()) :: {String.t(), [non_neg_integer()]} | nil
  def amounts(text) do
    with currency when is_binary(currency) <- currency(text) do
      amounts =
        @amount
        |> Regex.scan(text)
        |> Enum.take(2)
        |> Enum.map(fn
          [_all, number] -> minor(number, nil, currency)
          [_all, number, mult] -> minor(number, mult, currency)
        end)

      {currency, amounts}
    end
  end

  defp currency(text) do
    case Regex.run(~r/\b([A-Z]{3})\b/, text) do
      [_all, code] when code in @codes ->
        code

      _none ->
        Enum.find_value(@symbols, fn {symbol, code} -> String.contains?(text, symbol) && code end)
    end
  end

  defp minor(number, mult, currency) do
    factor =
      case mult do
        m when m in ["K", "k"] -> 1_000
        m when m in ["M", "m"] -> 1_000_000
        _none -> 1
      end

    number
    |> String.replace(",", "")
    |> Decimal.new()
    |> Decimal.mult(factor)
    |> Decimal.mult(Integer.pow(10, Utils.Money.minor_digits(currency)))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end
end
