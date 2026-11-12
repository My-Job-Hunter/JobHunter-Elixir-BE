defmodule Core.Tasks.Checklist do
  @moduledoc """
  A task's checklist (AQ-02 §7.2, §7.3): lines added, renamed, ticked,
  removed and reordered by anyone who may change the task; ticked by the
  customer on a task given to them. Each change is a `checklist` line in
  the activity; the order is not (mCart: tidying is not news). Every
  verb answers the sheet.
  """

  alias Core.Tasks
  alias Core.Tasks.{Histories, Write}
  alias Data.Scope
  alias Data.TaskParts
  alias Data.Tasks.ChecklistItem

  @doc "`POST /tasks/:id/checklist {text}`."
  @spec add(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def add(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :checklist, id) do
      text = Tasks.stringify(params)["text"]

      change(scope, task, now, fn -> added(TaskParts.add_item(task.id, text)) end)
    end
  end

  @doc "`PATCH /tasks/:id/checklist/:item_id {text}`."
  @spec rename(Scope.t(), term(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def rename(%Scope{} = scope, id, item_id, params, %DateTime{} = now) do
    with {:ok, task, item} <- item(scope, :checklist, id, item_id) do
      text = Tasks.stringify(params)["text"]

      change(scope, task, now, fn -> renamed(item, TaskParts.update_part(item, %{text: text})) end)
    end
  end

  @doc "`POST /tasks/:id/checklist/:item_id/toggle`: staff who may change the task; the customer on a task given to them."
  @spec toggle(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def toggle(%Scope{} = scope, id, item_id, %DateTime{} = now) do
    action = if Scope.customer?(scope), do: :tick, else: :checklist

    with {:ok, task, item} <- item(scope, action, id, item_id) do
      at = if item.checked_at, do: nil, else: now

      change(scope, task, now, fn ->
        ticked = TaskParts.tick(item, at, Scope.user_id(scope))
        {:ok, [tick_line(:checklist, item.id, item.text, item.checked_at, ticked.checked_at)]}
      end)
    end
  end

  @doc "`DELETE /tasks/:id/checklist/:item_id`."
  @spec remove(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def remove(%Scope{} = scope, id, item_id, %DateTime{} = now) do
    with {:ok, task, item} <- item(scope, :checklist, id, item_id) do
      change(scope, task, now, fn ->
        TaskParts.delete_part(item)
        {:ok, [Histories.line(:checklist, item.id, nil, item.text, nil)]}
      end)
    end
  end

  @doc "`PUT /tasks/:id/checklist/order {ids}`: every line, in its new order."
  @spec reorder(Scope.t(), term(), term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def reorder(%Scope{} = scope, id, ids, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :checklist, id) do
      if is_list(ids) and TaskParts.reorder(ChecklistItem, task.id, ids),
        do: Tasks.answer(scope, {:ok, task}, now),
        else: {:error, {:invalid, %{"ids" => ["must be every line of the checklist, once"]}}}
    end
  end

  defp added({:ok, item}), do: {:ok, [Histories.line(:checklist, nil, item.id, nil, item.text)]}
  defp added(error), do: error

  defp renamed(item, {:ok, new}),
    do: {:ok, [Histories.line(:checklist, item.text, new.text, item.text, new.text)]}

  defp renamed(_item, error), do: error

  @doc false
  # A ticked line or step, as the activity says it: "☐ text" → "☑ text".
  def tick_line(field, id, text, from_at, to_at) do
    Histories.line(
      field,
      state(id, from_at),
      state(id, to_at),
      box(text, from_at),
      box(text, to_at)
    )
  end

  defp state(id, nil), do: "open:#{id}"
  defp state(id, _at), do: "done:#{id}"

  defp box(text, nil), do: "☐ " <> text
  defp box(text, _at), do: "☑ " <> text

  defp item(scope, action, id, item_id) do
    with {:ok, task} <- Tasks.fetch(scope, action, id),
         %{} = item <- TaskParts.get_item(task.id, item_id) || {:error, :not_found},
         do: {:ok, task, item}
  end

  defp change(scope, task, now, fun) do
    result =
      Write.change(scope, task, now, fn _group ->
        with({:ok, lines} <- fun.(), do: {:ok, lines, []})
      end)

    Tasks.answer(scope, result, now)
  end
end
