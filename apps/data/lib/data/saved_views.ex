defmodule Data.SavedViews do
  @moduledoc """
  A person's saved views (AQ-04B §5.1, §9). Storage only: a view is its
  owner's alone, and `Core.SavedViews` asks for nobody else's.
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.SavedViews.SavedView

  @doc "A person's views of a screen (every screen when `nil`), in their order."
  @spec list(binary(), atom() | nil) :: [SavedView.t()]
  def list(user_id, screen) do
    query =
      from(v in SavedView,
        where: v.user_id == ^user_id,
        order_by: [asc: v.screen, asc: v.position, asc: v.inserted_at, asc: v.id]
      )

    query = if screen, do: where(query, [v], v.screen == ^screen), else: query
    Repo.all(query)
  end

  @doc "One of the person's views; `nil` for anyone else's, or a malformed id."
  @spec get(binary(), term()) :: SavedView.t() | nil
  def get(user_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(SavedView, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  def get(_user_id, _id), do: nil

  @doc "The position after the person's last view of a screen."
  @spec next_position(binary(), atom()) :: non_neg_integer()
  def next_position(user_id, screen) do
    from(v in SavedView,
      where: v.user_id == ^user_id and v.screen == ^screen,
      select: max(v.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      n -> n + 1
    end
  end

  @spec create(map()) :: {:ok, SavedView.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %SavedView{} |> SavedView.changeset(attrs) |> Repo.insert()

  @spec update(SavedView.t(), map()) :: {:ok, SavedView.t()} | {:error, Ecto.Changeset.t()}
  def update(%SavedView{} = view, attrs), do: view |> SavedView.changeset(attrs) |> Repo.update()

  @spec delete(SavedView.t()) :: {:ok, SavedView.t()} | {:error, Ecto.Changeset.t()}
  def delete(%SavedView{} = view), do: Repo.delete(view)
end
