defmodule Core.Tasks.People do
  @moduledoc """
  A task's people (AQ-02 §7.2): who is on it (`PUT /tasks/:id/assignees`),
  who watches, who muted it. Staff only — the customer's part is
  `customer_access` (QP2-2). A new assignee is told (`tasks.assigned`); a
  watcher is not given work (QP2-16), and a muted person hears nothing but
  a mention.

  A task In progress wears its primary's stage, so a new primary takes the
  task without the old one's stage.
  """

  alias Core.Realtime
  alias Core.Tasks
  alias Core.Tasks.{Histories, Notices, Person, Words, Write}
  alias Data.Scope
  alias Data.Tasks, as: Store

  @doc "`PUT /tasks/:id/assignees {primary_user_id?, secondary_user_ids}`: the set, replaced."
  @spec put_assignees(Scope.t(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def put_assignees(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Tasks.stringify(params)

    with {:ok, task} <- Tasks.fetch(scope, :assign, id),
         {:ok, primary, secondary} <- Tasks.assignees(scope, task.team_id, params) do
      Tasks.answer(
        scope,
        Write.commit(fn -> assign(scope, task, primary, secondary, now) end),
        now
      )
    end
  end

  defp assign(scope, task, primary, secondary, now) do
    before = assigned_ids(task)
    old_primary = Enum.find_value(task.participants, &(&1.level == :primary && &1.user_id))
    :ok = Store.put_assignees(task, primary, secondary)

    if old_primary != primary and task.stage_id,
      do: {:ok, _moved} = Store.move(task, %{"state" => task.state, "stage_id" => nil})

    updated = Store.reload(task)
    group = Histories.group_id()
    after_ids = assigned_ids(updated)

    lines =
      [
        Histories.line(
          :assignees,
          joined(before),
          joined(after_ids),
          names(task, before),
          names(updated, after_ids)
        )
      ] ++
        Histories.diff(task, updated, Tasks.zone(scope))

    :ok = Histories.write(scope, task.id, group, lines, now)
    told = Notices.assigned(scope, updated, after_ids -- before, group)
    {:ok, updated, [told, Realtime.task_events("task_updated", task, updated)]}
  end

  @doc "`POST /tasks/:id/watch {on}`: be told about a task without being given it."
  @spec watch(Scope.t(), term(), boolean() | term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def watch(%Scope{} = scope, id, on, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :watch, id) do
      Tasks.answer(scope, Write.commit(fn -> set_watch(scope, task, on?(on), now) end), now)
    end
  end

  defp set_watch(scope, task, on?, now) do
    before = watcher_ids(task)
    :ok = Store.put_flag(task, Scope.user_id(scope), :is_watcher, on?)
    updated = Store.reload(task)
    after_ids = watcher_ids(updated)

    line =
      Histories.line(
        :watchers,
        joined(before),
        joined(after_ids),
        names(task, before),
        names(updated, after_ids)
      )

    :ok = Histories.write(scope, task.id, Histories.group_id(), [line], now)
    {:ok, updated, Realtime.task_events("task_updated", task, updated, customer: false)}
  end

  @doc "`POST /tasks/:id/mute {on}`: hear nothing about it but a mention. Nobody else's business: no history."
  @spec mute(Scope.t(), term(), boolean() | term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def mute(%Scope{} = scope, id, on, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :watch, id) do
      :ok = Store.put_flag(task, Scope.user_id(scope), :is_muted, on?(on))
      Tasks.answer(scope, {:ok, task}, now)
    end
  end

  defp on?(on), do: on in [true, "true"]

  defp assigned_ids(task), do: for(p <- task.participants, p.level, do: p.user_id) |> Enum.sort()

  defp watcher_ids(task),
    do: for(p <- task.participants, p.is_watcher, do: p.user_id) |> Enum.sort()

  defp joined([]), do: nil
  defp joined(ids), do: Enum.join(ids, ",")

  # First names, as the activity says them: "Fiza and Qasim".
  defp names(_task, []), do: "Nobody"

  defp names(_task, ids) do
    users = Data.Accounts.users_by_id(ids)
    ids |> Enum.map(&Person.first_name(users[&1])) |> Enum.reject(&is_nil/1) |> Words.join()
  end
end
