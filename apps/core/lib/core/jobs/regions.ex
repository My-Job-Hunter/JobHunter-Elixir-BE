defmodule Core.Jobs.Regions do
  @moduledoc """
  The countries each of `Data.Vocabulary.regions/0` may mean (ISO alpha-2),
  **pure**: what the suggestion score reads to say a profile *may be* in a
  job's region (AQ-03 §9, half marks). A region is a hiring habit, not a
  treaty, so the lists are generous; nothing else reads them.
  """

  @eu ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE)
  @europe @eu ++ ~w(GB NO CH IS LI UA RS BA ME MK AL MD BY XK AD MC SM VA)
  @mena ~w(AE SA QA KW BH OM YE IQ IR JO LB SY IL PS EG LY TN DZ MA TR)
  @africa ~w(DZ AO BJ BW BF BI CV CM CF TD KM CD CG CI DJ EG GQ ER SZ ET GA GM GH GN GW KE LS LR
             LY MG MW ML MR MU MA MZ NA NE NG RW ST SN SC SL SO ZA SS SD TZ TG TN UG ZM ZW)
  @south_asia ~w(PK IN BD LK NP BT MV AF)
  @oceania ~w(AU NZ FJ PG WS TO VU SB KI FM MH NR PW TV)
  @latam ~w(MX GT BZ HN SV NI CR PA CU DO HT JM TT BS BB AR BO BR CL CO EC GY PY PE SR UY VE PR)
  @apac @south_asia ++
          @oceania ++
          ~w(CN JP KR KP MN TW HK MO SG MY ID TH VN PH KH LA MM BN TL KZ UZ KG TJ TM)

  @members %{
    "europe" => @europe,
    "eu" => @eu,
    "uk_ireland" => ~w(GB IE),
    "north_america" => ~w(US CA MX),
    "us" => ~w(US),
    "canada" => ~w(CA),
    "latam" => @latam,
    "emea" => Enum.uniq(@europe ++ @mena ++ @africa),
    "apac" => @apac,
    "mena" => @mena,
    "south_asia" => @south_asia,
    "africa" => @africa,
    "oceania" => @oceania
  }

  @doc "Every region, with its countries."
  def members, do: @members

  @doc """
  Whether `country` may be in any of `regions`.

      iex> Core.Jobs.Regions.in_any?("PK", ["south_asia"])
      true
      iex> Core.Jobs.Regions.in_any?("PK", ["eu", "us"])
      false
  """
  @spec in_any?(String.t(), [String.t()]) :: boolean()
  def in_any?(country, regions),
    do: Enum.any?(regions, &(country in Map.get(@members, to_string(&1), [])))
end
