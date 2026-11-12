defmodule Core.Approvals.Proposed do
  @moduledoc """
  An approval's **proposed value** (AQ-07 §5.1, §11.4, QP7-3), read from a
  body into the version's typed columns per kind — never `jsonb`: the CV
  (`cv_for_job`, a live document of the lead's profile), the bid and
  Connects (`proposal`), the expectation (`rate`, all three), the pitch and
  skills (`profile_change`, at least one). A member that doesn't fit the
  kind is a field error on `proposed.<member>`; a `null` member is as if
  it weren't sent.
  """

  alias Core.Approvals.Ask
  alias Core.Leads
  alias Data.Vocabulary

  @members ~w(document_id bid_minor bid_currency bid_period connects expectation_minor
              expectation_currency expectation_period title headline summary skill_ids)
  @fits %{
    "cv_for_job" => ~w(document_id),
    "proposal" => ~w(bid_minor bid_currency bid_period connects),
    "rate" => ~w(expectation_minor expectation_currency expectation_period),
    "profile_change" => ~w(title headline summary skill_ids)
  }
  @bid_periods Vocabulary.bid_periods() |> Enum.map(&String.to_atom/1)
  @comp_periods Vocabulary.comp_periods() |> Enum.map(&String.to_atom/1)

  @doc """
  `proposed` as the kind's typed columns (`proposed_*`). A member that
  doesn't fit the kind is a field error on `proposed.<member>`; the CV, the
  expectation and at least one pitch field are what their kinds ask.
  """
  @spec columns(atom(), term(), map()) :: {:ok, map()} | {:error, term()}
  def columns(kind, raw, about) do
    raw = if is_map(raw), do: Leads.stringify(raw), else: %{}
    sent = for {k, v} <- raw, k in @members, not is_nil(v), into: %{}, do: {k, v}
    fits = Map.get(@fits, to_string(kind), [])

    case Enum.find(Map.keys(sent), &(&1 not in fits)) do
      nil -> by_kind(kind, sent, about)
      member -> Leads.invalid("proposed.#{member}", "doesn't fit #{article(kind)}")
    end
  end

  defp by_kind(:cv_for_job, sent, about) do
    case sent["document_id"] do
      nil ->
        Leads.invalid("proposed.document_id", "is required")

      id ->
        with {:ok, document_id} <- cv(id, about.lead),
             do: {:ok, %{proposed_document_id: document_id}}
    end
  end

  defp by_kind(:proposal, sent, _about) do
    with {:ok, bid} <- money(sent, "bid", @bid_periods, :optional),
         {:ok, connects} <- whole(sent["connects"], "proposed.connects", 32_767) do
      {:ok, Map.put(bid, :proposed_connects, connects)}
    end
  end

  defp by_kind(:rate, sent, _about),
    do: money(sent, "expectation", @comp_periods, :required)

  defp by_kind(:profile_change, sent, about) do
    with {:ok, title} <- text(sent["title"], "proposed.title", 120, :no_blank),
         {:ok, headline} <- text(sent["headline"], "proposed.headline", 220, :blank),
         {:ok, summary} <- text(sent["summary"], "proposed.summary", 20_000, :blank),
         {:ok, skill_ids} <- skills(sent["skill_ids"], about) do
      attrs = %{
        proposed_title: title,
        proposed_headline: headline,
        proposed_summary: summary,
        proposed_skill_ids: skill_ids
      }

      if Enum.all?(Map.values(attrs), &is_nil/1),
        do: Leads.invalid("proposed", "names a title, headline, summary or skills"),
        else: {:ok, attrs}
    end
  end

  defp by_kind(_kind, _sent, _about), do: {:ok, %{}}

  defp cv(id, lead) do
    case Data.Documents.get(to_string(id)) do
      %{profile_id: profile_id, archived_at: nil} = doc when profile_id == lead.profile_id ->
        {:ok, doc.id}

      _other ->
        Leads.invalid("proposed.document_id", "is not a document of this lead's profile")
    end
  end

  defp money(sent, name, periods, required) do
    parts = Enum.map(~w(minor currency period), &sent["#{name}_#{&1}"])

    case {Enum.count(parts, &(not is_nil(&1))), required} do
      {0, :optional} ->
        {:ok, %{}}

      {3, _required} ->
        [minor, currency, period] = parts

        with {:ok, minor} <- whole(minor, "proposed.#{name}_minor", nil),
             {:ok, currency} <- currency(currency, "proposed.#{name}_currency"),
             {:ok, period} <- period(period, periods, "proposed.#{name}_period") do
          {:ok,
           %{
             :"proposed_#{name}_minor" => minor,
             :"proposed_#{name}_currency" => currency,
             :"proposed_#{name}_period" => period
           }}
        end

      _some ->
        Leads.invalid("proposed.#{name}_minor", "is needed with its currency and period")
    end
  end

  defp whole(nil, _field, _max), do: {:ok, nil}
  defp whole(n, _field, nil) when is_integer(n) and n >= 0, do: {:ok, n}
  defp whole(n, _field, max) when is_integer(n) and n >= 0 and n <= max, do: {:ok, n}

  defp whole(n, field, max) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> whole(i, field, max)
      _bad -> Leads.invalid(field, "is a whole number")
    end
  end

  defp whole(_n, field, _max), do: Leads.invalid(field, "is a whole number, not below 0")

  defp currency(c, field) do
    if is_binary(c) and Regex.match?(~r/^[A-Z]{3}$/, c),
      do: {:ok, c},
      else: Leads.invalid(field, "is not an ISO currency code")
  end

  defp period(p, periods, field) do
    case Ask.pick(p, periods) do
      nil -> Leads.invalid(field, "is one of #{Enum.join(periods, ", ")}")
      period -> {:ok, period}
    end
  end

  defp text(nil, _field, _max, _blank), do: {:ok, nil}

  defp text(value, field, max, blank) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" and blank == :no_blank -> Leads.invalid(field, "can't be blank")
      String.length(trimmed) > max -> Leads.invalid(field, "is too long (#{max} at most)")
      true -> {:ok, trimmed}
    end
  end

  defp text(_value, field, _max, _blank), do: Leads.invalid(field, "is text")

  defp skills(nil, _about), do: {:ok, nil}

  defp skills(ids, about) when is_list(ids) do
    wanted = ids |> Enum.map(&to_string/1) |> Enum.uniq()

    known =
      if Enum.all?(wanted, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))),
        do:
          about.customer.organisation_id
          |> Data.Skills.list(ids: wanted)
          |> Enum.map(& &1.id),
        else: []

    if Enum.all?(wanted, &(&1 in known)),
      do: {:ok, wanted},
      else: Leads.invalid("proposed.skill_ids", "names a skill that isn't in the list")
  end

  defp skills(_ids, _about), do: Leads.invalid("proposed.skill_ids", "is a list")

  defp article(kind) do
    words = String.replace(to_string(kind), "_", " ")
    if String.first(words) in ~w(a e i o u), do: "an #{words}", else: "a #{words}"
  end
end
