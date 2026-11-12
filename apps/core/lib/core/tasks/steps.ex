defmodule Core.Tasks.Steps do
  @moduledoc """
  A task's steps (AQ-02 §5.1, QP2-1, §7.2): each with one assignee — a staff
  person or the customer — and a tick, and *Nudge* (one a day per step).
  Whoever may change the task adds, edits, removes and orders them; a
  step's own assignee ticks it, the customer included. A step for the
  customer needs a task about one: "This task isn't about a customer."

  The activity names a step with its assignee after " · ", which the
  customer's view drops when the team hides names.
  """

  alias Core.Tasks
  alias Core.Tasks.{Checklist, Due, Histories, Notices, Person, Words, Write}
  alias Data.Accounts
  alias Data.Scope
  alias Data.TaskParts
  alias Data.Tasks.Step

  @doc "`POST /tasks/:id/steps {title, assignee_user_id?, is_for_customer?}`."
  @spec add(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def add(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :steps, id),
         {:ok, attrs} <-
           Tasks.step_attrs(Tasks.stringify(params), staff(scope, task), task.customer_id) do
      change(scope, task, now, fn group ->
        added(scope, task, TaskParts.add_step(task.id, attrs), group)
      end)
    end
  end

  @doc "`PATCH /tasks/:id/steps/:step_id {title?, assignee_user_id?, is_for_customer?}`."
  @spec update(Scope.t(), term(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def update(%Scope{} = scope, id, step_id, params, %DateTime{} = now) do
    params = Tasks.stringify(params)

    with {:ok, task, step} <- step(scope, :steps, id, step_id),
         {:ok, attrs} <-
           Tasks.step_attrs(merge(step, params), staff(scope, task), task.customer_id) do
      change(scope, task, now, fn group ->
        updated(scope, task, step, TaskParts.update_part(step, attrs), group)
      end)
    end
  end

  @doc "`POST /tasks/:id/steps/:step_id/toggle`: whoever may change the task, or the step's own assignee."
  @spec toggle(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def toggle(%Scope{} = scope, id, step_id, %DateTime{} = now) do
    with {:ok, task, step} <- step(scope, :read, id, step_id),
         :ok <- may_tick(scope, task, step) do
      at = if step.done_at, do: nil, else: now

      change(scope, task, now, fn _group ->
        ticked = TaskParts.tick(step, at, Scope.user_id(scope))

        {:ok,
         [Checklist.tick_line(:step, step.id, label(step, task), step.done_at, ticked.done_at)],
         []}
      end)
    end
  end

  defp may_tick(scope, task, step) do
    cond do
      Scope.customer?(scope) and step.is_for_customer -> :ok
      Scope.customer?(scope) -> {:error, {:forbidden, "This step isn't yours to do."}}
      step.assignee_user_id == Scope.user_id(scope) -> :ok
      true -> Core.Access.why_not(scope, :steps, {:task, task})
    end
  end

  @doc "`POST /tasks/:id/steps/:step_id/nudge`: `tasks.nudged` to its assignee, once per organisation day."
  @spec nudge(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def nudge(%Scope{} = scope, id, step_id, %DateTime{} = now) do
    with {:ok, task, step} <- step(scope, :steps, id, step_id),
         :ok <- nudgeable(step) do
      day = Due.today(now, Tasks.zone(scope))
      result = Write.commit(fn -> {:ok, task, Notices.nudged(scope, task, step, day)} end)
      Tasks.answer(scope, result, now)
    end
  end

  defp nudgeable(%{done_at: %DateTime{}}), do: {:error, {:invalid, %{"step" => ["is done"]}}}

  defp nudgeable(%{assignee_user_id: nil, is_for_customer: false}),
    do: {:error, {:invalid, %{"step" => ["has nobody to nudge"]}}}

  defp nudgeable(_step), do: :ok

  defp added(scope, task, {:ok, step}, group) do
    {:ok, [Histories.line(:step, nil, step.id, nil, label(step, task))],
     tell(scope, task, step, group)}
  end

  defp added(_scope, _task, error, _group), do: error

  defp updated(scope, task, step, {:ok, new}, group) do
    line = Histories.line(:step, value(step), value(new), label(step, task), label(new, task))

    moved? =
      {new.assignee_user_id, new.is_for_customer} != {step.assignee_user_id, step.is_for_customer}

    {:ok, [line], if(moved?, do: tell(scope, task, new, group), else: [])}
  end

  defp updated(_scope, _task, _step, error, _group), do: error

  # The body over the step as it is: a step for the customer has no staff
  # assignee, and a staff assignee takes it from the customer.
  defp merge(step, params) do
    merged =
      Map.merge(current(step), Map.take(params, ~w(title assignee_user_id is_for_customer)))

    cond do
      params["is_for_customer"] in [true, "true"] -> Map.put(merged, "assignee_user_id", nil)
      params["assignee_user_id"] -> Map.put(merged, "is_for_customer", false)
      true -> merged
    end
  end

  @doc "`DELETE /tasks/:id/steps/:step_id`."
  @spec remove(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def remove(%Scope{} = scope, id, step_id, %DateTime{} = now) do
    with {:ok, task, step} <- step(scope, :steps, id, step_id) do
      change(scope, task, now, fn _group ->
        TaskParts.delete_part(step)
        {:ok, [Histories.line(:step, step.id, nil, label(step, task), nil)], []}
      end)
    end
  end

  @doc "`PUT /tasks/:id/steps/order {ids}`."
  @spec reorder(Scope.t(), term(), term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def reorder(%Scope{} = scope, id, ids, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :steps, id) do
      if is_list(ids) and TaskParts.reorder(Step, task.id, ids),
        do: Tasks.answer(scope, {:ok, task}, now),
        else: {:error, {:invalid, %{"ids" => ["must be every step, once"]}}}
    end
  end

  # The step's new assignee hears of it: staff by `tasks.assigned`, the
  # customer too when the step is theirs.
  defp tell(scope, task, %{is_for_customer: true} = step, group),
    do: Notices.assigned_customer(scope, task, group, step: step.title)

  defp tell(_scope, _task, %{assignee_user_id: nil}, _group), do: []

  defp tell(scope, task, step, group),
    do: Notices.assigned(scope, task, [step.assignee_user_id], group, step: step.title)

  defp step(scope, action, id, step_id) do
    with {:ok, task} <- Tasks.fetch(scope, action, id),
         %{} = step <- TaskParts.get_step(task.id, step_id) || {:error, :not_found},
         do: {:ok, task, step}
  end

  defp staff(scope, task), do: Tasks.staff_for(scope, task.team_id)

  defp current(step) do
    %{
      "title" => step.title,
      "assignee_user_id" => step.assignee_user_id,
      "is_for_customer" => step.is_for_customer
    }
  end

  defp value(step), do: "#{step.title}|#{step.assignee_user_id}|#{step.is_for_customer}"

  # "Record a 2-minute intro · Tanweer"
  defp label(step, task) do
    who =
      cond do
        step.is_for_customer ->
          task.customer && Words.first_name(task.customer)

        step.assignee_user_id ->
          step.assignee_user_id |> Accounts.get_user() |> Person.first_name()

        true ->
          nil
      end

    if who, do: step.title <> " · " <> who, else: step.title
  end

  defp change(scope, task, now, fun),
    do: Tasks.answer(scope, Write.change(scope, task, now, fun), now)
end
