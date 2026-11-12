defmodule Utils.Units do
  @moduledoc """
  Money across periods (AQ-03 QP3-9), pure. **Currencies are never
  converted** (PLAN §5.2); periods are, by the fixed factors every recruiter
  uses: an hour ×2080, a day ×260, a week ×52, a month ×12 to a year. A
  project budget compares only with another project budget.
  """

  @factors %{hour: 2080, day: 260, week: 52, month: 12, year: 1}

  @doc "The factor from each period to a year; `project` has none."
  @spec annual_factors() :: %{atom() => pos_integer()}
  def annual_factors, do: @factors

  @doc """
  An amount in minor units over `period`, as a year's worth; `nil` for a
  project budget or an unknown period.

      iex> Utils.Units.annualise(4_500, :hour)
      9_360_000
      iex> Utils.Units.annualise(150_000, "project")
      nil
  """
  @spec annualise(integer() | nil, atom() | String.t() | nil) :: integer() | nil
  def annualise(nil, _period), do: nil
  def annualise(minor, period) when is_binary(period), do: annualise(minor, to_period(period))

  def annualise(minor, period) when is_integer(minor) do
    case Map.fetch(@factors, period) do
      {:ok, factor} -> minor * factor
      :error -> nil
    end
  end

  @doc """
  Two amounts in comparable form: both annualised, or both project budgets.
  `{a, b}`, or `nil` when the periods cannot be compared.

      iex> Utils.Units.comparable({400_000, :month}, {4_500, :hour})
      {4_800_000, 9_360_000}
      iex> Utils.Units.comparable({150_000, :project}, {4_500, :hour})
      nil
  """
  @spec comparable({integer(), atom()}, {integer(), atom()}) :: {integer(), integer()} | nil
  def comparable({a, :project}, {b, :project}), do: {a, b}

  def comparable({a, period_a}, {b, period_b}) do
    case {annualise(a, period_a), annualise(b, period_b)} do
      {nil, _b} -> nil
      {_a, nil} -> nil
      pair -> pair
    end
  end

  defp to_period(period) do
    Enum.find(Map.keys(@factors), &(Atom.to_string(&1) == period)) ||
      if(period == "project", do: :project)
  end
end
