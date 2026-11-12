defmodule Core.Approvals.Reminders do
  @moduledoc """
  An approval's due reminders and auto-approve (AQ-07 §9, QP7-13, QP7-14),
  in-app (email and push are P8's), P6's pattern:

  - **Oban jobs planned when it is submitted or revised** (`plan/2`,
    inside its transaction): `due_soon` 24 hours before `due_at` and
    `overdue` at it (`Core.Workers.ApprovalReminder`, keyed by `(approval,
    kind, due_at)`), and auto-approve at `auto_approve_at`
    (`Core.Workers.ApprovalAutoApprove`, keyed by `(approval,
    auto_approve_at)`) — unique while incomplete, so planning twice plans
    once; a revision drops the old ones (`drop/1`) and plans again.
  - **A job finds its approval moved and does nothing**: no longer
    pending, or its due date not the one planned; a late `due_soon` after
    the due time says nothing (the `overdue` one speaks).
  - **The notifications are ensured** by `approval:<id>:<kind>:<due_at>`,
    so a job run twice tells nobody twice.

  **Expiry** is not a job but the hourly sweep
  (`Core.Workers.ApprovalExpirySweep`, `Core.Approvals.Act.expire/1`).
  `catch_up/1` sends what is due by `now` and approves what is past its
  time: the dev clock's way in (`POST /dev/sweeps`), since a moved clock
  does not move Oban's schedule.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Approvals.{Act, Notices}
  alias Core.Realtime
  alias Core.Workers.{ApprovalAutoApprove, ApprovalReminder}
  alias Data.Approvals, as: Store
  alias Data.Scope

  @soon 24 * 3600
  @workers ["Core.Workers.ApprovalReminder", "Core.Workers.ApprovalAutoApprove"]

  @doc "Plans a pending approval's jobs: each reminder still ahead of `now`, and auto-approve."
  @spec plan(map(), DateTime.t()) :: :ok
  def plan(%{state: :pending} = a, %DateTime{} = now) do
    shift = Core.Clock.offset_days() * 86_400

    if a.due_at do
      for {kind, at} <- [due_soon: DateTime.add(a.due_at, -@soon, :second), overdue: a.due_at],
          DateTime.after?(at, now) do
        %{approval_id: a.id, kind: to_string(kind), due_at: DateTime.to_iso8601(a.due_at)}
        |> ApprovalReminder.new(
          scheduled_at: DateTime.add(at, -shift, :second),
          unique: [period: :infinity, keys: [:approval_id, :kind, :due_at], states: :incomplete]
        )
        |> Oban.insert!()
      end
    end

    if a.auto_approve_at do
      %{approval_id: a.id, auto_approve_at: DateTime.to_iso8601(a.auto_approve_at)}
      |> ApprovalAutoApprove.new(
        scheduled_at: DateTime.add(a.auto_approve_at, -shift, :second),
        unique: [period: :infinity, keys: [:approval_id, :auto_approve_at], states: :incomplete]
      )
      |> Oban.insert!()
    end

    :ok
  end

  def plan(_a, _now), do: :ok

  @doc "Cancels an approval's jobs not yet run (a decision, a revision, a withdrawal, the expiry)."
  @spec drop(binary()) :: :ok
  def drop(approval_id) do
    {:ok, _count} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where:
            j.worker in ^@workers and fragment("?->>'approval_id'", j.args) == ^approval_id and
              j.state in ["scheduled", "available", "retryable"]
        )
      )

    :ok
  end

  @doc """
  A reminder job's work: `kind` (`"due_soon"` or `"overdue"`) for the
  approval planned due at `due_at` (ISO 8601). Answers `:sent` (the
  notices ensured, possibly already), or why it did nothing: `:gone`,
  `:moved`, `:early`, `:stale`.
  """
  @spec remind(term(), String.t(), String.t(), DateTime.t()) ::
          :sent | :gone | :moved | :early | :stale
  def remind(approval_id, kind, due_at, %DateTime{} = now) when kind in ["due_soon", "overdue"] do
    with %{} = a <- Store.get_for_system(approval_id) || :gone,
         :ok <- planned(a, due_at),
         :ok <- due(a, String.to_existing_atom(kind), now) do
      send_reminder(a, String.to_existing_atom(kind))
    end
  end

  defp planned(%{state: :pending, due_at: %DateTime{} = at}, due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, planned, _offset} -> if DateTime.compare(planned, at) == :eq, do: :ok, else: :moved
      _bad -> :moved
    end
  end

  defp planned(_a, _due_at), do: :moved

  @doc "Which reminder is due at `now` for a pending approval with a due date: `:overdue`, `:due_soon` or `nil`."
  @spec nearest(map(), DateTime.t()) :: :overdue | :due_soon | nil
  def nearest(%{due_at: %DateTime{} = due}, now) do
    cond do
      DateTime.compare(now, due) != :lt -> :overdue
      DateTime.diff(due, now, :second) <= @soon -> :due_soon
      true -> nil
    end
  end

  def nearest(_a, _now), do: nil

  defp due(a, kind, now) do
    case nearest(a, now) do
      ^kind -> :ok
      nil -> :early
      _other -> :stale
    end
  end

  defp send_reminder(a, kind) do
    scope = Scope.system(%{id: a.organisation_id})

    {:ok, events} =
      Data.Repo.transaction(fn -> scope |> Notices.due(a, kind) |> List.flatten() end)

    Realtime.send_all(events)
    :sent
  end

  @doc """
  The dev clock's catch-up: every reminder due by `now` and not yet sent
  (the nearest one only), then every auto-approve whose time has come.
  Answers `%{reminded, approved}`.
  """
  @spec catch_up(DateTime.t()) :: %{reminded: non_neg_integer(), approved: non_neg_integer()}
  def catch_up(%DateTime{} = now) do
    reminded =
      now
      |> DateTime.add(@soon, :second)
      |> Store.due_before_for_system()
      |> Enum.count(fn a ->
        case nearest(a, now) do
          nil -> false
          kind -> send_reminder(a, kind) == :sent
        end
      end)

    %{reminded: reminded, approved: Act.auto_approve_due(now).approved}
  end
end
