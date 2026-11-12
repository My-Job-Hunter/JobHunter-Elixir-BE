defmodule Core.Tasks.Stages do
  @moduledoc """
  A person's own In progress stages (AQ-02 §7.2, QP2-10; mCart's D45):
  each person their own, and nobody else's. Four suggestions live in code
  (§11): *Sourcing · Preparing · Waiting on the customer · Waiting on the
  recruiter*; `suggested` lists the ones not yet added. Removing a stage
  clears it from the tasks that wore it (the foreign key nilifies).
  """

  alias Data.Scope
  alias Data.TaskStages

  @suggested ["Sourcing", "Preparing", "Waiting on the customer", "Waiting on the recruiter"]

  @doc "`GET /me/stages`: `%{stages, suggested}`."
  @spec list(Scope.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope) do
    with :ok <- staff(scope) do
      stages = TaskStages.list(Scope.user_id(scope))
      taken = MapSet.new(stages, &String.downcase(&1.name))

      {:ok,
       %{
         stages: stages,
         suggested: Enum.reject(@suggested, &MapSet.member?(taken, String.downcase(&1)))
       }}
    end
  end

  @doc "`POST /me/stages {name}`, or `{suggested: true}` for every suggestion not yet added."
  @spec create(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with :ok <- staff(scope),
         {:ok, %{suggested: missing}} <- list(scope) do
      names = if params["suggested"] in [true, "true"], do: missing, else: [params["name"]]

      with :ok <- add_each(Scope.user_id(scope), names), do: list(scope)
    end
  end

  defp add_each(user_id, names) do
    Enum.reduce_while(names, :ok, fn name, :ok -> added(TaskStages.create(user_id, name)) end)
  end

  defp added({:ok, _stage}), do: {:cont, :ok}
  defp added(error), do: {:halt, error}

  @doc "`PATCH /me/stages/:id {name}`."
  @spec rename(Scope.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def rename(%Scope{} = scope, id, params) do
    name = Map.get(params, "name") || Map.get(params, :name)

    with {:ok, stage} <- own(scope, id),
         {:ok, _renamed} <- TaskStages.rename(stage, name),
         do: list(scope)
  end

  @doc "`DELETE /me/stages/:id`."
  @spec delete(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def delete(%Scope{} = scope, id) do
    with {:ok, stage} <- own(scope, id) do
      TaskStages.delete(stage)
      list(scope)
    end
  end

  @doc "`PUT /me/stages/order {ids}`: every stage of the person's, once."
  @spec reorder(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def reorder(%Scope{} = scope, ids) do
    with :ok <- staff(scope) do
      if is_list(ids) and TaskStages.reorder(Scope.user_id(scope), ids),
        do: list(scope),
        else: {:error, {:invalid, %{"ids" => ["must be every one of your stages, once"]}}}
    end
  end

  defp own(scope, id) do
    with :ok <- staff(scope),
         %{} = stage <- TaskStages.get(Scope.user_id(scope), id) || {:error, :not_found},
         do: {:ok, stage}
  end

  defp staff(scope), do: if(Scope.staff?(scope), do: :ok, else: {:error, :not_found})
end
