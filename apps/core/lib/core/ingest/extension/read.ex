defmodule Core.Ingest.Extension.Read do
  @moduledoc """
  The small readings `Core.Ingest.Extension.Normalize` is built on, **pure**:
  a member of the fields as trimmed text, the first number in a text, a
  table's first match, the countries a place names, the moment "2 hours
  ago" names and how precisely, a link worth keeping.
  """

  @countries %{
    "united states" => "US",
    "united states of america" => "US",
    "usa" => "US",
    "us" => "US",
    "u.s." => "US",
    "u.s" => "US",
    "united kingdom" => "GB",
    "uk" => "GB",
    "great britain" => "GB",
    "england" => "GB",
    "canada" => "CA",
    "germany" => "DE",
    "france" => "FR",
    "spain" => "ES",
    "portugal" => "PT",
    "italy" => "IT",
    "netherlands" => "NL",
    "belgium" => "BE",
    "ireland" => "IE",
    "poland" => "PL",
    "sweden" => "SE",
    "norway" => "NO",
    "denmark" => "DK",
    "finland" => "FI",
    "switzerland" => "CH",
    "austria" => "AT",
    "czechia" => "CZ",
    "czech republic" => "CZ",
    "romania" => "RO",
    "ukraine" => "UA",
    "greece" => "GR",
    "hungary" => "HU",
    "estonia" => "EE",
    "lithuania" => "LT",
    "latvia" => "LV",
    "bulgaria" => "BG",
    "croatia" => "HR",
    "serbia" => "RS",
    "turkey" => "TR",
    "türkiye" => "TR",
    "israel" => "IL",
    "united arab emirates" => "AE",
    "uae" => "AE",
    "saudi arabia" => "SA",
    "qatar" => "QA",
    "egypt" => "EG",
    "pakistan" => "PK",
    "india" => "IN",
    "bangladesh" => "BD",
    "sri lanka" => "LK",
    "singapore" => "SG",
    "malaysia" => "MY",
    "indonesia" => "ID",
    "philippines" => "PH",
    "vietnam" => "VN",
    "thailand" => "TH",
    "china" => "CN",
    "japan" => "JP",
    "south korea" => "KR",
    "australia" => "AU",
    "new zealand" => "NZ",
    "brazil" => "BR",
    "mexico" => "MX",
    "argentina" => "AR",
    "colombia" => "CO",
    "chile" => "CL",
    "nigeria" => "NG",
    "kenya" => "KE",
    "south africa" => "ZA"
  }
  @codes @countries |> Map.values() |> Enum.uniq()

  @units %{
    "second" => 1,
    "minute" => 60,
    "min" => 60,
    "hour" => 3_600,
    "hr" => 3_600,
    "day" => 86_400,
    "week" => 7 * 86_400,
    "month" => 30 * 86_400,
    "year" => 365 * 86_400
  }

  @ago ~r/\b(\d+|an?|one)\+?\s*(second|minute|min|hour|hr|day|week|month|year)s?\b.*ago/i

  @doc "A nested member (`upwork`, `upwork.client`), or `%{}`."
  @spec sub(map(), String.t()) :: map()
  def sub(map, key) do
    case map[key] do
      %{} = sub -> sub
      _none -> %{}
    end
  end

  @doc ~S"""
  A member as text: whitespace collapsed, trimmed, at most 2000
  characters; `nil` when it is blank or not a string.

      iex> Core.Ingest.Extension.Read.text(%{"t" => "  Go \n dev "}, "t")
      "Go dev"
  """
  @spec text(map(), String.t()) :: String.t() | nil
  def text(map, key) do
    case map[key] do
      value when is_binary(value) ->
        value |> String.replace(~r/\s+/u, " ") |> String.trim() |> slice()

      _other ->
        nil
    end
  end

  defp slice(""), do: nil
  defp slice(text), do: String.slice(text, 0, 2000)

  @doc "The value of the first `{regex, value}` the text matches, or `nil`."
  @spec first_match(String.t() | nil, [{Regex.t(), term()}]) :: term()
  def first_match(nil, _table), do: nil

  def first_match(text, table),
    do: Enum.find_value(table, fn {regex, value} -> Regex.match?(regex, text) && value end)

  @doc """
  The first whole number in a text, commas allowed.

      iex> Core.Ingest.Extension.Read.integer("1,234 applicants")
      1234
  """
  @spec integer(String.t() | nil) :: non_neg_integer() | nil
  def integer(nil), do: nil

  def integer(text) do
    case Regex.run(~r/\d[\d,]*/, text) do
      [digits] -> digits |> String.replace(",", "") |> String.to_integer()
      nil -> nil
    end
  end

  @doc """
  The ISO countries a place names, by name or by code.

      iex> Core.Ingest.Extension.Read.countries("United Kingdom, US or Pakistan")
      ["GB", "US", "PK"]
  """
  @spec countries(String.t()) :: [String.t()]
  def countries(text) do
    text
    |> String.split(~r/[,;\/|]| or | and /u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&country/1)
    |> Enum.uniq()
  end

  defp country(part) do
    key = part |> String.downcase() |> String.replace(~r/\s+only$/, "") |> String.trim()

    cond do
      Map.has_key?(@countries, key) -> [@countries[key]]
      part =~ ~r/^[A-Z]{2}$/ and part in @codes -> [part]
      true -> []
    end
  end

  @doc """
  The moment "2 weeks ago", "an hour ago", "yesterday" or "just now" names,
  counted back from `now`, with how precisely it was said (one of its
  unit, in seconds); `nil` for anything else.

      iex> Core.Ingest.Extension.Read.ago("Last viewed by client: 2 hours ago", ~U[2026-11-11 09:00:00Z])
      {~U[2026-11-11 07:00:00Z], 3600}
  """
  @spec ago(String.t(), DateTime.t()) :: {DateTime.t(), pos_integer()} | nil
  def ago(text, now) do
    cond do
      text =~ ~r/yesterday/i -> {DateTime.add(now, -86_400, :second), 86_400}
      text =~ ~r/just now|moments? ago|today/i -> {now, 3_600}
      match = Regex.run(@ago, text) -> back(match, now)
      true -> nil
    end
  end

  defp back([_all, n, unit], now) do
    n = if n =~ ~r/^\d+$/, do: String.to_integer(n), else: 1
    unit = Map.fetch!(@units, String.downcase(unit))
    {DateTime.add(now, -n * unit, :second), max(unit, 60)}
  end

  @doc "The day an instant falls on in `zone` (UTC's when the zone is unknown)."
  @spec local_day(DateTime.t(), String.t()) :: Date.t()
  def local_day(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _unknown} -> DateTime.to_date(at)
    end
  end

  @doc "A web link worth keeping (`https://` added when it has no scheme), or `nil`."
  @spec link(String.t() | nil) :: String.t() | nil
  def link(nil), do: nil

  def link(url) do
    url = if url =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, do: url, else: "https://" <> url
    if Utils.SafeUrl.safe?(url), do: url, else: nil
  end
end
