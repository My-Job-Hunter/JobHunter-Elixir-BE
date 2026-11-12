defmodule Core.Leads.FollowUps do
  @moduledoc """
  Follow-ups (AQ-04B §6.2, QP4b-8, QP4b-9), **pure**: read from the lead and
  its events with the system's settings (`follow_up_gap_days` 3,
  `max_follow_ups` 2, `no_response_days` 14). Nothing is stored: the count
  is the `follow_up_logged` rows since the last `applied`.

  | State | When |
  |---|---|
  | `:due` | In progress at an `applied` or `seen` stage; the last `applied` or `follow_up_logged` is `follow_up_gap_days` old or older; fewer than `max_follow_ups` logged since the last `applied` |
  | `:no_response` | In progress at an `applied` or `seen` stage, `applied_at` `no_response_days` old or older, and no follow-up left to log, or the gap passed after the last one |
  | `:none` | anything else; **a response** — a move past the `applied` / `seen` stages, or (AQ-06 QP6-12) a `message_in` since the last `applied` — clears both |

  *No response?* wins over *Follow-up due* when both hold: fourteen quiet
  days after applying, a follow-up still owed is no longer the next thing.
  A custom stage counts as its anchor's kind.
  """

  @waiting [:applied, :seen]
  @day 86_400

  @type settings :: %{
          follow_up_gap_days: pos_integer(),
          max_follow_ups: pos_integer(),
          no_response_days: pos_integer()
        }
  @type result :: %{
          state: :due | :no_response | :none,
          count: non_neg_integer(),
          of: pos_integer(),
          since: DateTime.t() | nil,
          number: pos_integer() | nil
        }

  @doc """
  Where a lead stands on follow-ups at `now`. `lead` carries `state`,
  `applied_at`, `archived_at` and `stage` (`kind`, `anchor_kind`) or
  `stage_kind`; `events` are its ledger rows (`kind`, `occurred_at`), any
  order, any kinds. `number` is the follow-up now owed (the 1st, the 2nd).
  """
  @spec assess(map(), [map()], settings(), DateTime.t()) :: result()
  def assess(lead, events, settings, %DateTime{} = now) do
    of = settings.max_follow_ups
    anchor = last(events, :applied) || Map.get(lead, :applied_at)
    logged = logged_since(events, anchor)
    base = %{state: :none, count: length(logged), of: of, since: nil, number: nil}

    if waiting?(lead) and not is_nil(anchor) and not answered?(events, anchor),
      do: waiting(base, lead, anchor, logged, settings, now),
      else: base
  end

  defp waiting(%{count: count, of: of} = base, lead, anchor, logged, settings, now) do
    last = Enum.max([anchor | Enum.map(logged, & &1.occurred_at)], DateTime)
    gap_at = add_days(last, settings.follow_up_gap_days)
    gap_passed? = not DateTime.after?(gap_at, now)
    silent_at = add_days(lead.applied_at || anchor, settings.no_response_days)
    silent? = not DateTime.after?(silent_at, now)

    cond do
      silent? and (count >= of or gap_passed?) ->
        %{base | state: :no_response, since: Enum.max([silent_at, gap_at], DateTime)}

      count < of and gap_passed? ->
        %{base | state: :due, since: gap_at, number: count + 1}

      true ->
        base
    end
  end

  @doc "Whether the lead is waiting on an answer: In progress at an `applied` or `seen` stage, not archived."
  @spec waiting?(map()) :: boolean()
  def waiting?(lead) do
    Map.get(lead, :state) == :in_progress and is_nil(Map.get(lead, :archived_at)) and
      stage_kind(lead) in @waiting
  end

  defp stage_kind(%{stage_kind: kind}) when not is_nil(kind), do: kind
  defp stage_kind(%{stage: %{kind: :custom, anchor_kind: anchor}}), do: anchor
  defp stage_kind(%{stage: %{kind: kind}}), do: kind
  defp stage_kind(_lead), do: nil

  # AQ-06 QP6-12: an inbound message since the last application is a response.
  defp answered?(events, anchor) do
    Enum.any?(
      events,
      &(&1.kind == :message_in and DateTime.compare(&1.occurred_at, anchor) != :lt)
    )
  end

  defp last(events, kind) do
    events
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.occurred_at)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp logged_since(_events, nil), do: []

  defp logged_since(events, anchor) do
    Enum.filter(
      events,
      &(&1.kind == :follow_up_logged and DateTime.compare(&1.occurred_at, anchor) != :lt)
    )
  end

  defp add_days(at, days), do: DateTime.add(at, days * @day, :second)
end
