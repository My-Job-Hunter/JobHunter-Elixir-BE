defmodule Core.Tasks.Due do
  @moduledoc """
  Due reminders and overdue notices (AQ-02 §8, QP2-13): **one scan, every
  five minutes** (`Core.Workers.TaskDueScan`), taking `now`. For every open,
  live, non-draft task with a due it ensures:

  - `tasks.due_soon` once the reminder time has passed (`due_at` minus
    `reminder_minutes`), to the assignees and the customer when the task is
    given to them — "*…* is due at 15:00" in each reader's zone. A scan
    that comes more than an hour after the due itself says nothing: by then
    the task is overdue, and that is the notice;
  - `tasks.overdue` once the due has passed — a time, or the end of a day in
    the organisation's zone — to the assignees (else the author) and the
    customer when given it.

  **Idempotent by construction**: each row is ensured by a key carrying the
  due (`task:<id>:reminder:<due_at>`, `task:<id>:overdue:<due>`), so a scan
  run twice raises once, and a due that moves raises again.
  """

  alias Core.Access.Tasks, as: TaskAccess
  alias Core.Tasks.{Notices, Words, Write}
  alias Data.Accounts
  alias Data.Scope
  alias Data.Tasks, as: Store

  @grace_minutes 60

  @doc "Runs the scan at `now`. Answers how many notifications it wrote."
  @spec scan(DateTime.t()) :: non_neg_integer()
  def scan(%DateTime{} = now) do
    Store.list_due_for_system()
    |> Enum.map(fn task ->
      {:ok, written} =
        Write.commit(fn ->
          events = raise_for(task, now)
          {:ok, Enum.count(events, &match?({_topic, "notification_created", _p}, &1)), events}
        end)

      written
    end)
    |> Enum.sum()
  end

  defp raise_for(task, now) do
    scope = Scope.system(task.organisation)
    zone = task.organisation.timezone

    for kind <- due(task, now, zone), {user_id, user_zone} <- recipients(task, kind) do
      Notices.system(
        scope,
        user_id,
        "tasks.#{kind}",
        task,
        title(kind, task, user_zone),
        key(kind, task)
      )
    end
    |> List.flatten()
  end

  @doc """
  Which notices a task is due, **pure**: `:due_soon` when its reminder time
  has passed and the due itself not by more than an hour; `:overdue` when
  its due time, or the end of its due day in `zone`, has passed.
  """
  @spec due(map(), DateTime.t(), String.t()) :: [:due_soon | :overdue]
  def due(task, now, zone) do
    Enum.filter([:due_soon, :overdue], &due?(&1, task, now, zone))
  end

  defp due?(:due_soon, %{due_at: %DateTime{} = at, reminder_minutes: minutes}, now, _zone)
       when is_integer(minutes) do
    remind_at = DateTime.add(at, -minutes, :minute)

    DateTime.compare(remind_at, now) != :gt and
      DateTime.compare(now, DateTime.add(at, @grace_minutes, :minute)) == :lt
  end

  defp due?(:overdue, %{due_at: %DateTime{} = at}, now, _zone),
    do: DateTime.compare(at, now) != :gt

  defp due?(:overdue, %{due_on: %Date{} = on}, now, zone),
    do: Date.compare(today(now, zone), on) == :gt

  defp due?(_kind, _task, _now, _zone), do: false

  @doc "The day it is at `now` in `zone`."
  @spec today(DateTime.t(), String.t()) :: Date.t()
  def today(%DateTime{} = now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(now)
    end
  end

  # `{user_id, zone}` for everyone told: the assignees (not muted) — for an
  # overdue task with none, its author — and the customer when it is given to them.
  defp recipients(task, kind) do
    muted = for p <- task.participants, p.is_muted, do: p.user_id

    assignees =
      for p <- task.participants,
          p.level,
          p.user_id not in muted,
          do: {p.user_id, zone_of(p.user, "Etc/UTC")}

    staff =
      if assignees == [] and kind == :overdue and task.author_user_id not in [nil | muted] and
           task.author_user_id != customer_user(task),
         do: [{task.author_user_id, zone_of(Accounts.get_user(task.author_user_id), "Etc/UTC")}],
         else: assignees

    staff ++ customer(task)
  end

  defp customer(%{customer_access: :assigned, customer: %{user_id: id} = c} = task)
       when is_binary(id) do
    if TaskAccess.customer_sees?(task),
      do: [{id, zone_of(Accounts.get_user(id), c.timezone)}],
      else: []
  end

  defp customer(_task), do: []

  defp customer_user(%{customer: %{user_id: id}}), do: id
  defp customer_user(_task), do: nil

  defp zone_of(%{person: %{timezone: zone}}, _fallback) when is_binary(zone), do: zone
  defp zone_of(_user, fallback), do: fallback

  defp title(:due_soon, task, zone),
    do: "#{Words.quoted(task.title)} is due at #{Words.clock(task.due_at, zone)}"

  defp title(:overdue, task, _zone), do: "#{Words.quoted(task.title)} is overdue"

  defp key(:due_soon, task), do: "task:#{task.id}:reminder:#{DateTime.to_iso8601(task.due_at)}"

  defp key(:overdue, %{due_at: %DateTime{} = at} = task),
    do: "task:#{task.id}:overdue:#{DateTime.to_iso8601(at)}"

  defp key(:overdue, task), do: "task:#{task.id}:overdue:#{Date.to_iso8601(task.due_on)}"
end
