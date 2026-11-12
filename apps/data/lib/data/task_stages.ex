defmodule Data.TaskStages do
  @moduledoc "A person's own In progress stages (AQ-02 §5.1, QP2-10). Storage only; each person their own."

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Tasks.{Stage, Task}

  @doc "The person's stages in order, each with `in_use` (how many tasks wear it)."
  @spec list(binary()) :: [Stage.t()]
  def list(user_id) do
    in_use =
      from(t in Task,
        where: not is_nil(t.stage_id),
        group_by: t.stage_id,
        select: %{stage_id: t.stage_id, n: count(t.id)}
      )

    from(s in Stage,
      left_join: u in subquery(in_use),
      on: u.stage_id == s.id,
      where: s.user_id == ^user_id,
      order_by: [asc: s.position, asc: s.inserted_at],
      select: %{s | in_use: coalesce(u.n, 0)}
    )
    |> Repo.all()
  end

  @doc "One of the person's stages, or `nil`."
  @spec get(binary(), term()) :: Stage.t() | nil
  def get(user_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Stage, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  @spec create(binary(), String.t() | nil) :: {:ok, Stage.t()} | {:error, Ecto.Changeset.t()}
  def create(user_id, name) do
    position =
      from(s in Stage, where: s.user_id == ^user_id, select: coalesce(max(s.position) + 1, 0))
      |> Repo.one()

    %Stage{}
    |> Stage.changeset(%{user_id: user_id, name: name, position: position})
    |> Repo.insert()
  end

  @spec rename(Stage.t(), String.t() | nil) :: {:ok, Stage.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Stage{} = stage, name), do: stage |> Stage.changeset(%{name: name}) |> Repo.update()

  @spec delete(Stage.t()) :: Stage.t()
  def delete(%Stage{} = stage), do: Repo.delete!(stage)

  @doc "The person's stages in the order of `ids`; `false` unless `ids` is exactly theirs."
  @spec reorder(binary(), [binary()]) :: boolean()
  def reorder(user_id, ids) do
    current = Repo.all(from(s in Stage, where: s.user_id == ^user_id, select: s.id))

    if Enum.sort(current) == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) do
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, position} ->
        from(s in Stage, where: s.id == ^id) |> Repo.update_all(set: [position: position])
      end)

      true
    else
      false
    end
  end
end
