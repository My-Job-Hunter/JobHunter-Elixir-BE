defmodule Core.Tasks.Write do
  @moduledoc """
  **One verb, one transaction** (AQ-02 §7): the change, its history rows, its
  notifications and (QP2-11) its audit row commit together or not at all,
  and the socket hears about it **after** the commit, ids only.

  `commit/1` runs `work`, which answers `{:ok, value, events}` (the events
  as `Core.Realtime` builds them), `{:ok, value}`, or `{:error, reason}`
  — which rolls everything back and sends nothing.
  """

  alias Core.Broadcast
  alias Core.Realtime
  alias Core.Tasks.Histories
  alias Data.Repo
  alias Data.Scope
  alias Data.Tasks, as: Store

  @depth {__MODULE__, :depth}
  @held {__MODULE__, :held}

  @doc """
  Runs `work` in a transaction; sends its events once it committed.

  **Nested, it joins the outer commit** (AQ-06: *Create job and lead* links
  the conversation in `POST /leads`'s own transaction; *Classify* runs
  P4a's verb inside its own): an inner `commit/1` inside an outer one holds
  its events until the outermost transaction commits, and drops them when
  it rolls back — so a broadcast never runs ahead of the commit that makes
  it true. Inside a plain `Repo.transaction/1` it sends as it always did.
  """
  @spec commit((-> {:ok, term(), list()} | {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def commit(work) when is_function(work, 0) do
    depth = Process.get(@depth, 0)
    if depth == 0, do: Process.delete(@held)
    Process.put(@depth, depth + 1)

    try do
      work
      |> transaction()
      |> Broadcast.after_commit(fn {_value, events} -> send_or_hold(depth, events) end)
      |> unwrap(depth)
    after
      if depth == 0, do: Process.delete(@depth), else: Process.put(@depth, depth)
    end
  end

  defp transaction(work) do
    Repo.transaction(fn ->
      case work.() do
        {:ok, value, events} -> {value, List.flatten(events)}
        {:ok, value} -> {value, []}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp unwrap({:ok, {value, _events}}, _depth), do: {:ok, value}

  defp unwrap({:error, _reason} = error, depth) do
    if depth == 0, do: Process.delete(@held)
    error
  end

  defp send_or_hold(0, events), do: Realtime.send_all((Process.delete(@held) || []) ++ events)
  defp send_or_hold(_nested, events), do: Process.put(@held, Process.get(@held, []) ++ events)

  @doc """
  A change to a task's parts, logged: `fun.(group_id)` makes the change and
  answers `{:ok, lines, told}` (history lines, notice events) or an error.
  The lines are written as one group, and the boards hear `task_updated`
  (not the customer's, with `customer: false`). Answers the task fresh.
  """
  @spec change(Scope.t(), map(), DateTime.t(), (binary() -> term()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def change(%Scope{} = scope, task, %DateTime{} = now, fun, opts \\ []) do
    commit(fn ->
      group = Histories.group_id()

      with {:ok, lines, told} <- fun.(group) do
        :ok = Histories.write(scope, task.id, group, lines, now)
        updated = Store.reload(task)
        {:ok, updated, [told, Realtime.task_events("task_updated", task, updated, opts)]}
      end
    end)
  end

  @doc "Unwraps `{:ok, value}` inside a transaction, rolling back on an error."
  @spec ok!({:ok, term()} | {:error, term()}) :: term()
  def ok!({:ok, value}), do: value
  def ok!({:error, reason}), do: Repo.rollback(reason)
end
