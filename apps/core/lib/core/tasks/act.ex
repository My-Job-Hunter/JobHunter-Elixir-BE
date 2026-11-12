defmodule Core.Tasks.Act do
  @moduledoc """
  The verbs that move a task (AQ-02 §7.2, §7.3), mCart's pattern: **load
  → permission → at-state check → move → tell → log → broadcast**, one
  transaction. Every move carries the state the client saw (`from`); a task
  that moved meanwhile answers `{:error, {:task_moved, task}}`, the 409
  `task_moved` ("This task moved while you were looking. It's now In
  progress.").

  | Verb | From | To |
  |---|---|---|
  | `start` | draft · to do · on hold | in progress (a stage of the primary's, or none) |
  | `hold` | to do · in progress | on hold, with a reason; *Resume* goes back where it was |
  | `resume` | on hold | where it was held from |
  | `done` | to do · in progress · on hold | done |
  | `reopen` | done · closed | to do |
  | `close` | to do · in progress · on hold | closed: not needed · won't do · duplicate, a note |
  | `move` | anything | what a drop sends: `{state, stage_id?, reason?, note?}` |
  | `withdraw` | the customer's own, open | closed as withdrawn |

  Archive hides a task and is recoverable (QP2-12); a draft is deleted, by
  its author only; both, and unarchive, are audited (QP2-11).

  Back to Drafts is its author's call alone: a draft is seen by nobody else.
  Leaving Drafts tells everyone it gives work to (QP2-8); Done tells the
  author, assignees, watchers and the customer who sees it.
  """

  alias Core.Audit
  alias Core.Leads.TaskLinks
  alias Core.Realtime
  alias Core.Tasks
  alias Core.Tasks.{Histories, Notices, Words, Write}
  alias Data.Scope
  alias Data.Tasks, as: Store
  alias Data.TaskStages

  @open [:todo, :in_progress, :on_hold]
  @verbs %{
    start: {[:draft, :todo, :on_hold], :in_progress},
    hold: {[:todo, :in_progress], :on_hold},
    resume: {[:on_hold], :resume},
    done: {@open, :done},
    reopen: {[:done, :closed], :todo},
    close: {@open, :closed},
    withdraw: {@open, :closed}
  }
  @staff_reasons ~w(not_needed wont_do duplicate)
  @draft_words "Only its author can put a task back in Drafts."
  @cleared %{
    "stage_id" => nil,
    "held_at" => nil,
    "hold_reason" => nil,
    "held_from_state" => nil,
    "done_at" => nil,
    "done_by_user_id" => nil,
    "closed_at" => nil,
    "closed_reason" => nil,
    "closed_note" => nil,
    "closed_by_user_id" => nil
  }

  @doc "A verb on a task: `start`, `hold`, `resume`, `done`, `reopen`, `close`, `move`. Answers the sheet."
  @spec run(Scope.t(), atom(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def run(%Scope{} = scope, verb, id, params, %DateTime{} = now)
      when verb in [:start, :hold, :resume, :done, :reopen, :close, :move] do
    act(scope, :move, verb, id, Tasks.stringify(params), now)
  end

  @doc "The portal's verbs: `done` and `reopen` on a task given to the customer, `withdraw` on their own."
  @spec portal(Scope.t(), atom(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def portal(%Scope{} = scope, verb, id, params, %DateTime{} = now)
      when verb in [:done, :reopen, :withdraw] do
    action = if verb == :withdraw, do: :withdraw, else: :complete
    act(scope, action, verb, id, Map.take(Tasks.stringify(params), ["from"]), now)
  end

  defp act(scope, action, verb, id, params, now) do
    with {:ok, task} <- Tasks.fetch(scope, action, id),
         :ok <- at_state(task, params["from"]),
         :ok <- portal_reopen(action, verb, task),
         {:ok, target} <- target(verb, task, params),
         {:ok, attrs} <- attrs(scope, verb, target, task, params, now) do
      Tasks.answer(scope, write(scope, task, attrs, now), now)
    end
  end

  defp write(scope, task, attrs, now) do
    if same?(task, attrs),
      do: {:ok, task},
      else: Write.commit(fn -> move(scope, task, attrs, now) end)
  end

  @doc "`:ok` when the task is still in the state the client saw; the 409 otherwise."
  @spec at_state(map(), term()) :: :ok | {:error, term()}
  def at_state(_task, nil), do: {:error, {:missing, :from}}

  def at_state(task, from) do
    if to_string(task.state) == to_string(from),
      do: :ok,
      else: {:error, {:task_moved, Data.Repo.preload(task, :stage)}}
  end

  # The customer reopens what was marked done, never what the team closed.
  defp portal_reopen(:complete, :reopen, %{state: state}) when state != :done,
    do: invalid("state", "can't reopen a task that is #{Words.state(state)}")

  defp portal_reopen(_action, _verb, _task), do: :ok

  defp target(:move, task, %{"state" => state}) when is_binary(state) do
    case Enum.find(Data.Tasks.Task.states(), &(Atom.to_string(&1) == state)) do
      nil -> invalid("state", "is not a state")
      :draft when task.state != :draft -> back_to_draft(task)
      to -> {:ok, to}
    end
  end

  defp target(:move, _task, _params), do: {:error, {:missing, :state}}

  defp target(verb, task, _params) do
    {from, to} = Map.fetch!(@verbs, verb)

    cond do
      task.state not in from ->
        invalid("state", "can't #{verb} a task that is #{Words.state(task.state)}")

      to == :resume ->
        {:ok, task.held_from_state || :todo}

      true ->
        {:ok, to}
    end
  end

  defp back_to_draft(task), do: {:ok, {:draft_by, task.author_user_id}}

  # The columns of the target state, every other state's cleared.
  defp attrs(scope, _verb, {:draft_by, author}, _task, _params, _now) do
    if author == Scope.user_id(scope),
      do: {:ok, Map.put(@cleared, "state", :draft)},
      else: {:error, {:forbidden, @draft_words}}
  end

  defp attrs(_scope, _verb, :in_progress, task, params, _now) do
    with {:ok, stage_id} <- stage(task, Tasks.blank(params["stage_id"])),
         do: {:ok, Map.merge(@cleared, %{"state" => :in_progress, "stage_id" => stage_id})}
  end

  defp attrs(_scope, _verb, :on_hold, task, params, now) do
    case Tasks.blank(params["reason"]) do
      nil ->
        {:error, {:missing, :reason}}

      reason ->
        {:ok,
         Map.merge(@cleared, %{
           "state" => :on_hold,
           "held_at" => now,
           "hold_reason" => String.slice(reason, 0, 1000),
           "held_from_state" =>
             if(task.state in [:todo, :in_progress], do: task.state, else: :todo)
         })}
    end
  end

  defp attrs(scope, _verb, :done, _task, _params, now),
    do:
      {:ok,
       Map.merge(@cleared, %{
         "state" => :done,
         "done_at" => now,
         "done_by_user_id" => Scope.user_id(scope)
       })}

  defp attrs(scope, verb, :closed, _task, params, now) do
    reason = if verb == :withdraw, do: "withdrawn", else: params["reason"]

    cond do
      is_nil(reason) ->
        {:error, {:missing, :reason}}

      verb != :withdraw and reason not in @staff_reasons ->
        invalid("reason", "is not one of: not needed, won't do, duplicate")

      true ->
        {:ok,
         Map.merge(@cleared, %{
           "state" => :closed,
           "closed_at" => now,
           "closed_reason" => reason,
           "closed_note" => Tasks.blank(params["note"]),
           "closed_by_user_id" => Scope.user_id(scope)
         })}
    end
  end

  defp attrs(_scope, _verb, to, _task, _params, _now) when to in [:todo, :draft],
    do: {:ok, Map.put(@cleared, "state", to)}

  # A stage belongs to the task's primary assignee — or its author when
  # nobody is primary (their own task on My board).
  defp stage(_task, nil), do: {:ok, nil}

  defp stage(task, stage_id) do
    case TaskStages.get(stage_owner(task), stage_id) do
      nil -> invalid("stage_id", "is not one of the primary assignee's stages")
      stage -> {:ok, stage.id}
    end
  end

  @doc "Whose stages a task in progress wears: its primary assignee's, else its author's."
  @spec stage_owner(map()) :: binary() | nil
  def stage_owner(task) do
    Enum.find_value(task.participants, task.author_user_id, &(&1.level == :primary && &1.user_id))
  end

  # A drop on the column it is already in, at the same stage, changes nothing.
  defp same?(task, attrs),
    do:
      attrs["state"] == task.state and
        (task.state != :in_progress or attrs["stage_id"] == task.stage_id)

  defp move(scope, task, attrs, now) do
    with {:ok, moved} <- Store.move(task, attrs) do
      group = Histories.group_id()

      :ok =
        Histories.write(
          scope,
          task.id,
          group,
          Histories.diff(task, moved, Tasks.zone(scope)),
          now
        )

      told =
        cond do
          task.state == :draft and moved.state != :draft ->
            Notices.became_real(scope, moved, group)

          moved.state == :done ->
            Notices.completed(scope, moved)

          true ->
            []
        end

      linked = TaskLinks.moved(scope, task, moved, now)
      {:ok, moved, [told, linked, Realtime.task_events("task_updated", task, moved)]}
    end
  end

  # ── Archive, unarchive, delete ──────────────────────────────────────────────

  @doc "`POST /tasks/:id/archive`: hidden, recoverable from the *Archived* filter (QP2-12)."
  @spec archive(Scope.t(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now), do: set_archived(scope, id, now, now)

  @doc "`POST /tasks/:id/unarchive`."
  @spec unarchive(Scope.t(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def unarchive(%Scope{} = scope, id, %DateTime{} = now), do: set_archived(scope, id, nil, now)

  defp set_archived(scope, id, at, now) do
    with {:ok, task} <- Tasks.fetch(scope, :archive, id) do
      Tasks.answer(scope, archive_write(scope, task, at, now), now)
    end
  end

  # Archiving an archived task (or the reverse) changes nothing.
  defp archive_write(scope, task, at, now) do
    if is_nil(task.archived_at) == is_nil(at),
      do: {:ok, task},
      else: Write.commit(fn -> archived(scope, task, at, now) end)
  end

  defp archived(scope, task, at, now) do
    {:ok, updated} = Store.archive(task, at, Scope.user_id(scope))
    {from_label, to_label} = if at, do: {nil, "Archived"}, else: {"Archived", nil}
    line = Histories.line(:archived, task.archived_at, at, from_label, to_label)
    :ok = Histories.write(scope, task.id, Histories.group_id(), [line], now)
    action = if at, do: "archived", else: "unarchived"

    {:ok, _event} =
      Audit.record(scope, action, updated,
        before: Tasks.snapshot(task),
        after: Tasks.snapshot(updated),
        now: now
      )

    event = if at, do: "task_deleted", else: "task_updated"
    {:ok, updated, Realtime.task_events(event, task, updated)}
  end

  @doc "`DELETE /tasks/:id`: a draft, by its author (QP2-12). It told nobody, so nothing is lost."
  @spec delete(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :delete, id),
         {:ok, _deleted} <-
           Write.commit(fn ->
             {:ok, _event} =
               Audit.record(scope, "deleted", task, before: Tasks.snapshot(task), now: now)

             {:ok, _gone} = Store.delete(task)
             {:ok, task, Realtime.task_events("task_deleted", nil, task)}
           end),
         do: :ok
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
