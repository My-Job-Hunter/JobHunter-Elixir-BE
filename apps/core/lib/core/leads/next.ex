defmodule Core.Leads.Next do
  @moduledoc """
  *Next* (AQ-04B §6.1, QP4b-10), **pure** and worded by the server, so the
  card, the Tracker row and the page's header say the same thing. The first
  that applies:

  1. the next scheduled meeting not yet over (AQ-06 §8.4): "Meeting ·
     Technical interview · Tue 14:00";
  2. the pending approval on the lead due soonest (AQ-07 QP7-18):
     "Approval · CV for Bamboo · due Thu";
  3. the earliest due, open task linked to the lead: "Task · Upload the
     updated CV · due Thu";
  4. *Follow-up due*: "Follow up · 1st of 2 · due since Mon";
  5. *No response?*: "No response in 14 days";
  6. nothing: `nil`.

  The shape is §8.4's: `{kind, words, at?, task_id?}`, AQ-06 §11.6 adding
  `meeting_id` (`kind: "meeting"`) and AQ-07 §11.4 `approval_id` (`kind:
  "approval"`), each `nil` on the others. A day within a week
  of today reads as its weekday ("Thu"), today as "today", anything further
  as "14 Nov", in the organisation's zone. A task due on a day (`due_on`)
  is placed at that day's start in the zone.
  """

  alias Core.Leads.FollowUps

  @open [:todo, :in_progress, :on_hold]

  @doc """
  *Next* for a lead: `tasks` are the tasks linked to it (`id`, `title`,
  `state`, `due_at`, `due_on`, `archived_at`), `follow_up` is
  `Core.Leads.FollowUps.assess/4`'s answer, `settings` carry
  `no_response_days`; `now` and `zone` place the words.
  """
  @spec of([map()], FollowUps.result() | nil, map(), DateTime.t(), String.t()) :: map() | nil
  def of(tasks, follow_up, settings, %DateTime{} = now, zone),
    do: of(nil, tasks, follow_up, settings, now, zone)

  @doc "*Next* with the lead's next meeting first (`meeting`: `id`, `title`, `starts_at`, or `nil`)."
  @spec of(map() | nil, [map()], FollowUps.result() | nil, map(), DateTime.t(), String.t()) ::
          map() | nil
  def of(meeting, tasks, follow_up, settings, %DateTime{} = now, zone),
    do: of(meeting, nil, tasks, follow_up, settings, now, zone)

  @doc """
  *Next* with the lead's next meeting first, then its pending approval due
  soonest (`approval`: `id`, `title`, `due_at`, or `nil`; AQ-07 QP7-18).
  """
  @spec of(
          map() | nil,
          map() | nil,
          [map()],
          FollowUps.result() | nil,
          map(),
          DateTime.t(),
          String.t()
        ) :: map() | nil
  def of(%{} = meeting, _approval, _tasks, _follow_up, _settings, %DateTime{} = now, zone) do
    %{
      kind: "meeting",
      words:
        "Meeting · #{meeting.title} · #{day(meeting.starts_at, now, zone)} #{clock(meeting.starts_at, zone)}",
      at: meeting.starts_at,
      task_id: nil,
      meeting_id: meeting.id,
      approval_id: nil
    }
  end

  def of(nil, %{} = approval, _tasks, _follow_up, _settings, %DateTime{} = now, zone) do
    %{
      kind: "approval",
      words: "Approval · #{approval.title} · due #{day(approval.due_at, now, zone)}",
      at: approval.due_at,
      task_id: nil,
      meeting_id: nil,
      approval_id: approval.id
    }
  end

  def of(nil, nil, tasks, follow_up, settings, %DateTime{} = now, zone) do
    case earliest(tasks, zone) do
      {task, at} ->
        %{
          kind: "task",
          words: "Task · #{task.title} · due #{day(at, now, zone)}",
          at: at,
          task_id: task.id,
          meeting_id: nil,
          approval_id: nil
        }

      nil ->
        from_follow_up(follow_up, settings, now, zone)
    end
  end

  defp clock(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  defp from_follow_up(%{state: :due, number: n, of: of, since: since}, _settings, now, zone) do
    %{
      kind: "follow_up",
      words: "Follow up · #{ordinal(n)} of #{of} · due since #{day(since, now, zone)}",
      at: since,
      task_id: nil,
      meeting_id: nil,
      approval_id: nil
    }
  end

  defp from_follow_up(%{state: :no_response, since: since}, settings, _now, _zone) do
    %{
      kind: "no_response",
      words: "No response in #{settings.no_response_days} days",
      at: since,
      task_id: nil,
      meeting_id: nil,
      approval_id: nil
    }
  end

  defp from_follow_up(_none, _settings, _now, _zone), do: nil

  @doc "The earliest due among the open, live tasks, as `{task, at}`; `nil` when none has a due."
  @spec earliest([map()], String.t()) :: {map(), DateTime.t()} | nil
  def earliest(tasks, zone) do
    tasks
    |> Enum.filter(&(&1.state in @open and is_nil(Map.get(&1, :archived_at))))
    |> Enum.flat_map(fn task ->
      case due(task, zone) do
        nil -> []
        at -> [{task, at}]
      end
    end)
    |> Enum.min_by(fn {task, at} -> {DateTime.to_unix(at, :microsecond), task.id} end, fn ->
      nil
    end)
  end

  defp due(%{due_at: %DateTime{} = at}, _zone), do: at

  defp due(%{due_on: %Date{} = on}, zone) do
    case DateTime.new(on, ~T[00:00:00], zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:gap, _before, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, at, _later} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(on, ~T[00:00:00])
    end
  end

  defp due(_task, _zone), do: nil

  @doc ~S"""
  A day as *Next* says it, against `now` in `zone`: "today", a weekday
  within six days either way, else "14 Nov".

      iex> Core.Leads.Next.day(~U[2026-11-12 10:00:00Z], ~U[2026-11-11 09:00:00Z], "Etc/UTC")
      "Thu"
      iex> Core.Leads.Next.day(~U[2026-11-11 18:00:00Z], ~U[2026-11-11 09:00:00Z], "Etc/UTC")
      "today"
      iex> Core.Leads.Next.day(~U[2026-12-01 10:00:00Z], ~U[2026-11-11 09:00:00Z], "Etc/UTC")
      "1 Dec"
  """
  @spec day(DateTime.t(), DateTime.t(), String.t()) :: String.t()
  def day(%DateTime{} = at, %DateTime{} = now, zone) do
    local = local(at, zone)
    today = local(now, zone) |> DateTime.to_date()
    diff = Date.diff(DateTime.to_date(local), today)

    cond do
      diff == 0 -> "today"
      abs(diff) <= 6 -> Calendar.strftime(local, "%a")
      true -> Calendar.strftime(local, "%-d %b")
    end
  end

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _unknown -> at
    end
  end

  @doc ~S"""
  An ordinal: "1st", "2nd", "3rd", "4th", "11th", "22nd".

      iex> Enum.map([1, 2, 3, 4, 11, 12, 13, 21, 22], &Core.Leads.Next.ordinal/1)
      ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"]
  """
  @spec ordinal(pos_integer()) :: String.t()
  def ordinal(n) when rem(n, 100) in [11, 12, 13], do: "#{n}th"
  def ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  def ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  def ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  def ordinal(n), do: "#{n}th"
end
