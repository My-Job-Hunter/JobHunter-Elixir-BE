defmodule Data.TaskParts do
  @moduledoc """
  A task's parts (AQ-02 §5.1): checklist lines, steps, links, relations and
  files. Storage only; `Core.Tasks.Parts` decides who may touch them and
  writes the history beside each change.

  Positions are written as the next free one on insert and rewritten in
  one pass by `reorder/3`; nothing else moves them.
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Tasks.{ChecklistItem, Link, Relation, Step, TaskMedia}

  # ── Checklist lines and steps ───────────────────────────────────────────────

  @doc "A checklist line of the task, or `nil`."
  @spec get_item(binary(), term()) :: ChecklistItem.t() | nil
  def get_item(task_id, id), do: get_child(ChecklistItem, task_id, id)

  @doc "A step of the task, or `nil`."
  @spec get_step(binary(), term()) :: Step.t() | nil
  def get_step(task_id, id), do: get_child(Step, task_id, id)

  @doc "A link of the task, or `nil`."
  @spec get_link(binary(), term()) :: Link.t() | nil
  def get_link(task_id, id), do: get_child(Link, task_id, id)

  defp get_child(schema, task_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(schema, id: uuid, task_id: task_id)
      :error -> nil
    end
  end

  @spec add_item(binary(), String.t() | nil) ::
          {:ok, ChecklistItem.t()} | {:error, Ecto.Changeset.t()}
  def add_item(task_id, text) do
    %ChecklistItem{}
    |> ChecklistItem.changeset(%{
      task_id: task_id,
      text: text,
      position: next(ChecklistItem, task_id)
    })
    |> Repo.insert()
  end

  @spec add_step(binary(), map()) :: {:ok, Step.t()} | {:error, Ecto.Changeset.t()}
  def add_step(task_id, attrs) do
    %Step{}
    |> Step.changeset(Map.merge(attrs, %{task_id: task_id, position: next(Step, task_id)}))
    |> Repo.insert()
  end

  @doc "Changes a line's text or a step's title and assignee."
  @spec update_part(ChecklistItem.t() | Step.t(), map()) ::
          {:ok, ChecklistItem.t() | Step.t()} | {:error, Ecto.Changeset.t()}
  def update_part(%schema{} = part, attrs), do: part |> schema.changeset(attrs) |> Repo.update()

  @doc "Ticks (`at`) or unticks (`nil`) a line or a step, as `user_id`."
  @spec tick(ChecklistItem.t() | Step.t(), DateTime.t() | nil, binary() | nil) ::
          ChecklistItem.t() | Step.t()
  def tick(%schema{} = part, at, user_id),
    do: part |> schema.tick_changeset(at, user_id) |> Repo.update!()

  @spec delete_part(struct()) :: struct()
  def delete_part(part), do: Repo.delete!(part)

  @doc "The task's lines or steps (`schema`) in order, as `ids` says; answers `false` unless `ids` is exactly them."
  @spec reorder(module(), binary(), [binary()]) :: boolean()
  def reorder(schema, task_id, ids) when schema in [ChecklistItem, Step] do
    current = Repo.all(from(p in schema, where: p.task_id == ^task_id, select: p.id))

    if Enum.sort(current) == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) do
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, position} ->
        from(p in schema, where: p.id == ^id) |> Repo.update_all(set: [position: position])
      end)

      true
    else
      false
    end
  end

  defp next(schema, task_id) do
    from(p in schema, where: p.task_id == ^task_id, select: coalesce(max(p.position) + 1, 0))
    |> Repo.one()
  end

  # ── Links ───────────────────────────────────────────────────────────────────

  @spec add_link(binary(), map()) :: {:ok, Link.t()} | {:error, Ecto.Changeset.t()}
  def add_link(task_id, attrs) do
    %Link{}
    |> Link.changeset(Map.merge(attrs, %{task_id: task_id, position: next_link(task_id)}))
    |> Repo.insert()
  end

  defp next_link(task_id) do
    from(l in Link, where: l.task_id == ^task_id, select: coalesce(max(l.position) + 1, 0))
    |> Repo.one()
  end

  # ── Relations ───────────────────────────────────────────────────────────────

  @spec add_relation(map()) :: {:ok, Relation.t()} | {:error, Ecto.Changeset.t()}
  def add_relation(attrs), do: %Relation{} |> Relation.changeset(attrs) |> Repo.insert()

  @doc "A relation touching the task from either end, with both tasks, or `nil`."
  @spec get_relation(binary(), term()) :: Relation.t() | nil
  def get_relation(task_id, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Relation{} = r <- Repo.get(Relation, uuid),
         true <- task_id in [r.from_task_id, r.to_task_id] do
      Repo.preload(r, [:from_task, :to_task])
    else
      _other -> nil
    end
  end

  # ── Files ───────────────────────────────────────────────────────────────────

  @spec add_media(binary(), binary(), binary() | nil) ::
          {:ok, TaskMedia.t()} | {:error, Ecto.Changeset.t()}
  def add_media(task_id, media_id, user_id) do
    position =
      from(m in TaskMedia, where: m.task_id == ^task_id, select: coalesce(max(m.position) + 1, 0))
      |> Repo.one()

    %TaskMedia{}
    |> TaskMedia.changeset(%{
      task_id: task_id,
      media_id: media_id,
      position: position,
      added_by_user_id: user_id
    })
    |> Repo.insert()
  end

  @doc "A file on the task, with its media, or `nil`."
  @spec get_media(binary(), term()) :: TaskMedia.t() | nil
  def get_media(task_id, media_id) do
    case Ecto.UUID.cast(media_id) do
      {:ok, uuid} ->
        TaskMedia |> Repo.get_by(task_id: task_id, media_id: uuid) |> Repo.preload(:media)

      :error ->
        nil
    end
  end

  @spec remove_media(TaskMedia.t()) :: non_neg_integer()
  def remove_media(%TaskMedia{} = link) do
    {count, _rows} =
      from(m in TaskMedia, where: m.task_id == ^link.task_id and m.media_id == ^link.media_id)
      |> Repo.delete_all()

    count
  end
end
