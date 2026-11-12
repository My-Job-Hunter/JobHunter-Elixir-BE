defmodule Data.TaskHistories do
  @moduledoc """
  A task's activity rows (AQ-02 §5.1). Storage only: what counts as a
  change and what it is labelled is `Core.Tasks.Histories`'s, and which
  rows the customer reads is decided there on read (§6.4).
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Tasks.History

  @doc "Writes the rows of one change group; a row naming no change is refused by the CHECK."
  @spec record([map()]) :: :ok
  def record([]), do: :ok

  def record(rows) do
    Enum.each(rows, fn row -> %History{} |> History.changeset(row) |> Repo.insert!() end)
  end

  @doc "A task's rows, newest first, with their actors."
  @spec list(binary()) :: [History.t()]
  def list(task_id) do
    from(h in History,
      where: h.task_id == ^task_id,
      order_by: [desc: h.changed_at, desc: h.id],
      preload: [actor_user: [person: :photo]]
    )
    |> Repo.all()
  end
end
