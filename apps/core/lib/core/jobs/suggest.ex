defmodule Core.Jobs.Suggest do
  @moduledoc """
  The suggestion score (AQ-03 §9, QP3-10), **pure**: one rule, one home,
  read by the list's filter, the sheet and (P4a) the portal. Computed on
  read; nothing is stored.

  | Part | Weight | Full marks | Half | Nothing |
  |---|---|---|---|---|
  | `skills` | 40 | every required skill is the profile's (nice-to-have count half) | — | in proportion |
  | `engagement` | 15 | the job's engagement is one of the profile's | — | otherwise |
  | `workplace` | 15 | one of the profile's, and a `country_list` includes a profile country | `region` the profile may be in | otherwise |
  | `money` | 15 | same currency, comparable period (QP3-9), the job's top ≥ the profile's floor | undisclosed | below the floor |
  | `timezone` | 10 | a required zone is the profile's, or the profile's day covers the overlap window | within 3 h | otherwise |
  | `seniority` | 5 | equal | adjacent | otherwise |

  **A part the job or the profile is silent on is left out and the rest
  re-weighed**, so an unknown never counts against a job: the parts'
  weights always sum to 100. A different currency, or a project against a
  salary, is silence too — they cannot be compared (PLAN §5.2).

  The profile's working day, for the overlap window, is 09:00–17:00 in each
  of its `work_timezones`; offsets are read at `now`, so a zone's summer
  time counts.

  **A deal breaker scores 0** (the user, 2026-11-10: workplace "is deal
  breaker"): a job whose workplace or engagement the profile doesn't take,
  or a remote job open only to countries or regions the profile isn't in —
  the `workplace` or `engagement` part scoring nothing — is never
  suggested, however well the rest fits. Its parts are still listed, that
  part's words beginning "Deal breaker: ".
  """

  alias Core.Jobs.Regions
  alias Utils.Units

  @deal_breakers [:engagement, :workplace]
  @weights [skills: 40, engagement: 15, workplace: 15, money: 15, timezone: 10, seniority: 5]
  @threshold 70
  @ladder [:internship, :entry, :associate, :mid_senior, :director, :executive]
  @day_start 9
  @day_hours 8

  @type part :: %{part: String.t(), weight: non_neg_integer(), got: float(), why: String.t()}
  @type result :: %{score: 0..100, parts: [part()]}

  @doc "The score from which a job is suggested for a profile (the chip, the filter)."
  def threshold, do: @threshold

  @doc "The full weight of each part, in order."
  def weights, do: @weights

  @doc """
  `profile` with its `profile_skills` (and their skills) against `job` with
  its `job_skills` (and theirs), at `now`.
  """
  @spec score(map(), map(), DateTime.t()) :: result()
  def score(profile, job, %DateTime{} = now) do
    known =
      for {part, weight} <- @weights,
          {got, why} <- part(part, profile, job, now),
          do: {part, weight, got, why}

    case Enum.sum(Enum.map(known, &elem(&1, 1))) do
      0 ->
        %{score: 0, parts: []}

      total ->
        score = Enum.sum(Enum.map(known, fn {_p, w, got, _why} -> w * got end)) / total * 100
        shares = reweigh(Enum.map(known, &elem(&1, 1)), total)
        broken? = Enum.any?(known, &breaks?/1)

        parts = known |> Enum.zip(shares) |> Enum.map(&view/1)

        %{score: if(broken?, do: 0, else: round(score)), parts: parts}
    end
  end

  defp view({{part, _w, got, why} = known, share}) do
    why = if breaks?(known), do: "Deal breaker: " <> why, else: why
    %{part: Atom.to_string(part), weight: share, got: Float.round(got / 1, 2), why: why}
  end

  # A job the profile can't take at all: the workplace or the engagement scores nothing.
  defp breaks?({part, _w, got, _why}), do: part in @deal_breakers and got == 0

  # The kept weights as shares of 100, by largest remainder, so they sum to 100.
  defp reweigh(weights, total) do
    exact = Enum.map(weights, &(&1 * 100 / total))
    floors = Enum.map(exact, &trunc/1)
    short = 100 - Enum.sum(floors)

    bumped =
      exact
      |> Enum.with_index()
      |> Enum.sort_by(fn {x, i} -> {-(x - trunc(x)), i} end)
      |> Enum.take(short)
      |> MapSet.new(fn {_x, i} -> i end)

    floors
    |> Enum.with_index()
    |> Enum.map(fn {f, i} -> if MapSet.member?(bumped, i), do: f + 1, else: f end)
  end

  # Each part answers `[{got, why}]`, or `[]` when it is left out.

  # ── Skills ──────────────────────────────────────────────────────────────────

  defp part(:skills, profile, job, _now) do
    asked = Enum.map(job.job_skills, &{&1.skill_id, &1.is_required, skill_name(&1)})
    held = MapSet.new(profile.profile_skills, & &1.skill_id)

    if asked == [] or MapSet.size(held) == 0,
      do: [],
      else: [skills_part(asked, held)]
  end

  # ── Engagement ──────────────────────────────────────────────────────────────

  defp part(:engagement, profile, job, _now) do
    takes = profile.engagement_types || []

    cond do
      is_nil(job.engagement) or takes == [] ->
        []

      to_string(job.engagement) in takes ->
        [{1.0, "#{label(job.engagement)} is one this profile takes"}]

      true ->
        [{0.0, "This profile doesn't take #{lower(job.engagement)}"}]
    end
  end

  # ── Workplace ───────────────────────────────────────────────────────────────

  defp part(:workplace, profile, job, _now) do
    takes = (profile.workplace_types || []) -- ["unknown"]

    cond do
      job.workplace in [nil, :unknown] or takes == [] ->
        []

      to_string(job.workplace) not in takes ->
        [{0.0, "This profile doesn't take #{lower(job.workplace)} work"}]

      true ->
        [scope_part(job, profile.work_countries || [])]
    end
  end

  # ── Money ───────────────────────────────────────────────────────────────────

  defp part(:money, profile, job, _now) do
    top = job.comp_max_minor || job.comp_min_minor

    cond do
      is_nil(profile.min_comp_minor) ->
        []

      job.is_comp_undisclosed and is_nil(top) ->
        [{0.5, "Pay not disclosed"}]

      is_nil(top) or job.comp_currency != profile.min_comp_currency ->
        []

      true ->
        money_part({top, job.comp_period}, {profile.min_comp_minor, profile.min_comp_period})
    end
  end

  # ── Time zone ───────────────────────────────────────────────────────────────

  defp part(:timezone, profile, job, now) do
    zones = Enum.filter(profile.work_timezones || [], &offset(&1, now))
    required = Enum.filter(job.required_timezones || [], &offset(&1, now))
    window = window(job)

    if zones == [] or (required == [] and is_nil(window)) do
      []
    else
      [best_zone(zones_part(zones, required, now), window_part(zones, window, now))]
    end
  end

  # ── Seniority ───────────────────────────────────────────────────────────────

  defp part(:seniority, profile, job, _now) do
    with a when is_integer(a) <- Enum.find_index(@ladder, &(&1 == job.seniority)),
         b when is_integer(b) <- Enum.find_index(@ladder, &(&1 == profile.seniority)) do
      case abs(a - b) do
        0 -> [{1.0, "#{label(job.seniority)}, as the profile is"}]
        1 -> [{0.5, "One step from the profile's #{lower(profile.seniority)}"}]
        _far -> [{0.0, "#{label(job.seniority)}; the profile is #{lower(profile.seniority)}"}]
      end
    else
      _unknown -> []
    end
  end

  # ── The parts' pieces ───────────────────────────────────────────────────────

  defp skills_part(asked, held) do
    held? = fn {id, _required?, _name} -> MapSet.member?(held, id) end
    {required, nice} = Enum.split_with(asked, fn {_id, required?, _name} -> required? end)

    got =
      (Enum.count(required, held?) + Enum.count(nice, held?) / 2) /
        (length(required) + length(nice) / 2)

    {has, lacks} = Enum.split_with(required ++ nice, held?)
    {got, skills_why(names(has), names(lacks))}
  end

  defp scope_part(%{remote_scope: :country_list} = job, countries) do
    open = job.allowed_countries || []

    cond do
      countries == [] ->
        {0.5, "Open to #{list(open)}; the profile names no country"}

      Enum.any?(countries, &(&1 in open)) ->
        {1.0, "Open to #{list(Enum.filter(countries, &(&1 in open)))}"}

      true ->
        {0.0, "Only from #{list(open)}"}
    end
  end

  defp scope_part(%{remote_scope: :region} = job, countries) do
    regions = job.allowed_regions || []

    if countries == [] or Enum.any?(countries, &Regions.in_any?(&1, regions)),
      do: {0.5, "Within #{list(Enum.map(regions, &lower/1))}, where the profile may be"},
      else: {0.0, "Only within #{list(Enum.map(regions, &lower/1))}"}
  end

  defp scope_part(job, _countries), do: {1.0, "#{label(job.workplace)} suits this profile"}

  defp money_part({top, period}, {floor, floor_period}) do
    case Units.comparable({top, period}, {floor, floor_period}) do
      nil -> []
      {a, b} when a >= b -> [{1.0, "Pays at least the profile's floor"}]
      _below -> [{0.0, "Pays below the profile's floor"}]
    end
  end

  defp zones_part(_zones, [], _now), do: nil

  defp zones_part(zones, required, now) do
    shared = Enum.filter(zones, &(&1 in required))

    gap =
      for z <- zones, r <- required, reduce: nil do
        best -> min(best || 24, hours_apart(offset(z, now), offset(r, now)))
      end

    cond do
      shared != [] -> {1.0, "#{hd(shared)} is one of the job's zones"}
      gap <= 3 -> {0.5, "Within 3 hours of #{list(required)}"}
      true -> {0.0, "More than 3 hours from #{list(required)}"}
    end
  end

  defp window_part(_zones, nil, _now), do: nil

  defp window_part(zones, {from, to, needed}, now) do
    covered =
      zones
      |> Enum.map(fn zone ->
        start = :math.fmod(@day_start - offset(zone, now) / 3600 + 48, 24)
        overlap({start, start + @day_hours}, {from, to})
      end)
      |> Enum.max()

    cond do
      covered >= needed -> {1.0, "The profile's day covers the job's hours"}
      covered + 3 >= needed -> {0.5, "Within 3 hours of the job's hours"}
      true -> {0.0, "Too far from the job's hours"}
    end
  end

  defp best_zone(nil, window), do: window
  defp best_zone(zones, nil), do: zones
  defp best_zone({a, _} = zones, {b, _} = window), do: if(a >= b, do: zones, else: window)

  # The overlap window in UTC hours, `to` past midnight when it wraps, and
  # how many of its hours a person must cover.
  defp window(%{overlap_from_time: %Time{} = from, overlap_to_time: %Time{} = to} = job) do
    from_h = from.hour + from.minute / 60
    to_h = to.hour + to.minute / 60
    to_h = if to_h <= from_h, do: to_h + 24, else: to_h
    {from_h, to_h, min(job.min_overlap_hours || to_h - from_h, to_h - from_h)}
  end

  defp window(_job), do: nil

  # Hours two daily spans share, on a 24-hour circle.
  defp overlap({a1, a2}, {b1, b2}) do
    for shift <- [-24, 0, 24], reduce: 0 do
      best -> max(best, max(0, min(a2, b2 + shift) - max(a1, b1 + shift)))
    end
  end

  defp offset(zone, now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> local.utc_offset + local.std_offset
      _unknown -> nil
    end
  end

  defp hours_apart(a, b) do
    diff = rem(abs(a - b), 86_400)
    min(diff, 86_400 - diff) / 3600
  end

  # ── Words ───────────────────────────────────────────────────────────────────

  defp skills_why(has, []), do: "Has #{list(has)}"
  defp skills_why([], lacks), do: "Lacks #{list(lacks)}"
  defp skills_why(has, lacks), do: "Has #{list(has)}, not #{list(lacks)}"

  defp skill_name(%{skill: %{name: name}}), do: name
  defp skill_name(_link), do: "a skill"

  defp names(entries), do: Enum.map(entries, fn {_id, _r, name} -> name end)

  defp label(value), do: value |> lower() |> String.capitalize()
  defp lower(value), do: value |> to_string() |> String.replace("_", " ")

  defp list([]), do: "nowhere named"
  defp list([one]), do: one
  defp list(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
