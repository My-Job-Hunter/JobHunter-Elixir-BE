defmodule Core.Tasks.Links do
  @moduledoc """
  A task's links and relations (AQ-02 §5.1, §7.2). A link is http or https
  only (`Utils.SafeUrl`, failing closed). A relation joins two tasks of the
  organisation the caller sees — *blocks*, *relates to* (its own inverse),
  *duplicates* — read from both ends; informational, never a lock.
  Relations are staff business: the customer's activity never shows them.
  """

  alias Core.Tasks
  alias Core.Tasks.{Histories, Words, Write}
  alias Data.Scope
  alias Data.TaskParts

  @kinds Data.Vocabulary.task_relation_kinds()

  @doc "`POST /tasks/:id/links {url, label?}`."
  @spec add_link(Scope.t(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def add_link(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Tasks.stringify(params)

    with {:ok, task} <- Tasks.fetch(scope, :links, id) do
      attrs = %{
        url: params["url"],
        label: params["label"],
        added_by_user_id: Scope.user_id(scope)
      }

      change(scope, task, now, [], fn -> link_added(TaskParts.add_link(task.id, attrs)) end)
    end
  end

  @doc "`DELETE /tasks/:id/links/:link_id`: gone; the activity keeps that it was there."
  @spec remove_link(Scope.t(), term(), term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def remove_link(%Scope{} = scope, id, link_id, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :links, id),
         %{} = link <- TaskParts.get_link(task.id, link_id) || {:error, :not_found} do
      change(scope, task, now, [], fn ->
        TaskParts.delete_part(link)
        {:ok, [Histories.line(:link, link.url, nil, link.label, nil)]}
      end)
    end
  end

  @doc "`POST /tasks/:id/relations {task_id, kind}`: the other task must be one the caller sees."
  @spec add_relation(Scope.t(), term(), map(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def add_relation(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Tasks.stringify(params)

    with {:ok, task} <- Tasks.fetch(scope, :relations, id),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, other} <- other(scope, params["task_id"]) do
      attrs = %{
        from_task_id: task.id,
        to_task_id: other.id,
        kind: kind,
        created_by_user_id: Scope.user_id(scope)
      }

      change(scope, task, now, [customer: false], fn ->
        related(TaskParts.add_relation(attrs), kind, other)
      end)
    end
  end

  @doc "`DELETE /tasks/:id/relations/:relation_id`, from either end."
  @spec remove_relation(Scope.t(), term(), term(), DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def remove_relation(%Scope{} = scope, id, relation_id, %DateTime{} = now) do
    with {:ok, task} <- Tasks.fetch(scope, :relations, id),
         %{} = relation <- TaskParts.get_relation(task.id, relation_id) || {:error, :not_found} do
      other = if relation.from_task_id == task.id, do: relation.to_task, else: relation.from_task

      change(scope, task, now, [customer: false], fn ->
        TaskParts.delete_part(relation)

        {:ok,
         [Histories.line(:relation, relation.id, nil, relation_label(relation.kind, other), nil)]}
      end)
    end
  end

  defp link_added({:ok, link}), do: {:ok, [Histories.line(:link, nil, link.url, nil, link.label)]}
  defp link_added(error), do: error

  defp related({:ok, relation}, kind, other),
    do: {:ok, [Histories.line(:relation, nil, relation.id, nil, relation_label(kind, other))]}

  defp related(error, _kind, _other), do: error

  defp kind(kind) when kind in @kinds, do: {:ok, String.to_existing_atom(kind)}
  defp kind(nil), do: {:error, {:missing, :kind}}

  defp kind(_other),
    do: {:error, {:invalid, %{"kind" => ["is not blocks, relates_to or duplicates"]}}}

  defp other(_scope, nil), do: {:error, {:missing, :task_id}}

  defp other(scope, id) do
    case Tasks.fetch(scope, :read, id) do
      {:ok, other} -> {:ok, other}
      {:error, _not_found} -> {:error, :not_found}
    end
  end

  defp relation_label(kind, other), do: Words.relation(kind) <> " " <> Words.quoted(other.title)

  defp change(scope, task, now, opts, fun) do
    result =
      Write.change(
        scope,
        task,
        now,
        fn _group -> with({:ok, lines} <- fun.(), do: {:ok, lines, []}) end,
        opts
      )

    Tasks.answer(scope, result, now)
  end
end
