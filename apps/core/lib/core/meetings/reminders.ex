defmodule Core.Meetings.Reminders do
  @moduledoc """
  A meeting's reminders (AQ-06 §8.3, QP6-16): at **24 h, 1 h and 10 min**
  before, to the customer, the lead's owner and the staff attendees,
  in-app (email, push and a person's own preference are P8's).

  - **Oban jobs planned when the meeting is saved** (`plan/2`, inside its
    transaction), each keyed by `(meeting, offset, starts_at)` — unique
    while incomplete — so a reschedule's new jobs never collide with the
    old ones, which are cancelled (`drop/1`).
  - **A job finds its meeting moved or cancelled and does nothing**
    (mCart's timers): `remind/4` checks the status and the start it was
    planned for, and that this offset is still the nearest one due (a late
    24 h job after the 1 h mark says nothing, so nobody hears "in 24 hours"
    an hour before).
  - **The notifications are ensured** by `meeting:<id>:remind:<offset>:<starts_at>`,
    so a job run twice tells nobody twice.

  `catch_up/1` sends what is due by `now` for every scheduled meeting of
  the next day: the dev clock's way in (`POST /dev/sweeps`), since a moved
  clock does not move Oban's schedule.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Meetings.Notices
  alias Core.Realtime
  alias Core.Workers.MeetingReminder
  alias Data.Meetings, as: Store
  alias Data.Scope

  @offsets [1440, 60, 10]
  @worker "Core.Workers.MeetingReminder"

  @doc "The offsets, in minutes before the start."
  def offsets, do: @offsets

  @doc "Plans the jobs of a scheduled meeting: each offset still ahead of `now`."
  @spec plan(map(), DateTime.t()) :: :ok
  def plan(%{status: :scheduled} = meeting, %DateTime{} = now) do
    shift = Core.Clock.offset_days() * 86_400

    for offset <- @offsets,
        at = DateTime.add(meeting.starts_at, -offset * 60, :second),
        DateTime.after?(at, now) do
      %{meeting_id: meeting.id, offset: offset, starts_at: DateTime.to_iso8601(meeting.starts_at)}
      |> MeetingReminder.new(
        scheduled_at: DateTime.add(at, -shift, :second),
        unique: [period: :infinity, keys: [:meeting_id, :offset, :starts_at], states: :incomplete]
      )
      |> Oban.insert!()
    end

    :ok
  end

  def plan(_meeting, _now), do: :ok

  @doc "Cancels a meeting's reminder jobs not yet run (a reschedule, a cancel)."
  @spec drop(binary()) :: :ok
  def drop(meeting_id) do
    {:ok, _count} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker == @worker and fragment("?->>'meeting_id'", j.args) == ^meeting_id and
              j.state in ["scheduled", "available", "retryable"]
        )
      )

    :ok
  end

  @doc """
  A job's work: the reminder at `offset` for the meeting planned to start
  at `starts_at` (ISO 8601). Answers `:sent` (the notices ensured, possibly
  already), or why it did nothing: `:gone`, `:moved`, `:started`, `:stale`.
  """
  @spec remind(term(), pos_integer(), String.t(), DateTime.t()) ::
          :sent | :gone | :moved | :started | :stale
  def remind(meeting_id, offset, starts_at, %DateTime{} = now) do
    with %{} = meeting <- Store.get_for_system(meeting_id) || :gone,
         :ok <- planned(meeting, starts_at),
         :ok <- due(meeting, offset, now) do
      send_reminder(meeting, offset)
    end
  end

  defp planned(%{status: :scheduled, starts_at: at}, starts_at) do
    case DateTime.from_iso8601(starts_at) do
      {:ok, planned, _offset} -> if DateTime.compare(planned, at) == :eq, do: :ok, else: :moved
      _bad -> :moved
    end
  end

  defp planned(_cancelled_or_done, _starts_at), do: :moved

  # The meeting has not started, and no nearer offset is due already.
  defp due(meeting, offset, now) do
    cond do
      not DateTime.before?(now, meeting.starts_at) -> :started
      nearest(meeting, now) != offset -> :stale
      true -> :ok
    end
  end

  @doc "The nearest offset due at `now` for a meeting, or `nil` when none is yet."
  @spec nearest(map(), DateTime.t()) :: pos_integer() | nil
  def nearest(meeting, now) do
    minutes = DateTime.diff(meeting.starts_at, now, :second) / 60

    @offsets
    |> Enum.filter(&(minutes <= &1))
    |> Enum.min(fn -> nil end)
  end

  defp send_reminder(meeting, offset) do
    scope = Scope.system(%{id: meeting.organisation_id})

    {:ok, events} =
      Data.Repo.transaction(fn ->
        scope |> Notices.reminder(meeting, offset) |> List.flatten()
      end)

    Realtime.send_all(events)
    :sent
  end

  @doc "Every reminder due by `now` and not yet sent, for the meetings of the next day. Answers how many meetings."
  @spec catch_up(DateTime.t()) :: %{meetings: non_neg_integer()}
  def catch_up(%DateTime{} = now) do
    sent =
      now
      |> Store.starting_for_system(DateTime.add(now, 1440 * 60, :second))
      |> Enum.count(fn meeting ->
        case nearest(meeting, now) do
          nil -> false
          offset -> send_reminder(meeting, offset) == :sent
        end
      end)

    %{meetings: sent}
  end
end
