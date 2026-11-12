defmodule Core.SavedViews do
  @moduledoc """
  A person's saved views (AQ-04B §4, §8.1, §9, QP4b-16): one table for the
  Tracker, both lead boards, Jobs and the task board. A view keeps the
  URL's query **without the team** — `team`, `team_id`, `tab` and
  `columns` (the Tracker's columns are their own field) are dropped from
  what is sent, so a view works in every team — and, for the Tracker, its
  chosen columns in order (empty elsewhere). **Their owner's alone**: anyone
  else's view is not found. Not audited: a view is a person's own
  convenience, like a remembered filter.

  | Route | Body |
  |---|---|
  | `GET /saved-views?screen` | — |
  | `POST /saved-views` | `{screen, name, query, columns?}` |
  | `PATCH /saved-views/:id` | any of `{name, query, columns, position}` |
  | `DELETE /saved-views/:id` | — |

  `query` is the URL's query string (`state=in_progress&profile=…`, with
  or without its leading `?`) or an object of its parameters; either way
  it is stored as a query string.
  """

  alias Core.Access
  alias Data.SavedViews, as: Store
  alias Data.SavedViews.SavedView
  alias Data.Scope
  alias Data.Vocabulary

  @dropped ~w(team team_id tab columns)

  @doc "`GET /saved-views?screen`: the caller's views, of one screen or all."
  @spec list(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, params) do
    params = stringify(params)

    with :ok <- person(scope),
         {:ok, screen} <- screen(params["screen"], :optional) do
      {:ok, Enum.map(Store.list(Scope.user_id(scope), screen), &view/1)}
    end
  end

  @doc "`POST /saved-views {screen, name, query, columns?}`."
  @spec create(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params) do
    params = stringify(params)

    with :ok <- person(scope),
         {:ok, screen} <- screen(params["screen"], :required),
         {:ok, query} <- query(Map.get(params, "query", "")),
         {:ok, columns} <- columns(screen, Map.get(params, "columns", [])) do
      %{
        organisation_id: Scope.organisation_id(scope),
        user_id: Scope.user_id(scope),
        screen: screen,
        name: params["name"],
        query: query,
        columns: columns,
        position: Store.next_position(Scope.user_id(scope), screen)
      }
      |> Store.create()
      |> answer()
    end
  end

  @doc "`PATCH /saved-views/:id {name?, query?, columns?, position?}`."
  @spec update(Scope.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    params = stringify(params)

    with {:ok, view} <- fetch(scope, id),
         {:ok, attrs} <- changes(view, params) do
      view |> Store.update(attrs) |> answer()
    end
  end

  @doc "`DELETE /saved-views/:id`."
  @spec delete(Scope.t(), term()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id) do
    with {:ok, view} <- fetch(scope, id),
         {:ok, _deleted} <- Store.delete(view),
         do: :ok
  end

  @doc "A saved view (§8.4): `{id, screen, name, query, columns, position}`."
  @spec view(SavedView.t()) :: map()
  def view(%SavedView{} = v) do
    %{
      id: v.id,
      screen: v.screen,
      name: v.name,
      query: v.query,
      columns: v.columns,
      position: v.position
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp person(scope), do: if(Scope.user_id(scope), do: :ok, else: {:error, :not_found})

  defp fetch(scope, id) do
    with :ok <- person(scope),
         %SavedView{} = view <- Store.get(Scope.user_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :update, {:saved_view, view}),
         do: {:ok, view}
  end

  defp changes(view, params) do
    steps = [
      {"name", fn name -> {:ok, %{name: name}} end},
      {"query", fn q -> with {:ok, q} <- query(q), do: {:ok, %{query: q}} end},
      {"columns", fn c -> with {:ok, c} <- columns(view.screen, c), do: {:ok, %{columns: c}} end},
      {"position", &position/1}
    ]

    Enum.reduce_while(steps, {:ok, %{}}, fn {key, fun}, {:ok, acc} ->
      params |> Map.fetch(key) |> change(fun) |> merge(acc)
    end)
  end

  defp change(:error, _fun), do: {:ok, %{}}
  defp change({:ok, value}, fun), do: fun.(value)

  defp merge({:ok, change}, acc), do: {:cont, {:ok, Map.merge(acc, change)}}
  defp merge(error, _acc), do: {:halt, error}

  defp screen(nil, :optional), do: {:ok, nil}
  defp screen("", :optional), do: {:ok, nil}
  defp screen(nil, :required), do: {:error, {:missing, [:screen]}}

  defp screen(value, _need) do
    if to_string(value) in Vocabulary.saved_view_screens(),
      do: {:ok, String.to_atom(to_string(value))},
      else: invalid("screen", "is one of tracker, leads, jobs or board")
  end

  @doc false
  # The URL's query without the team, as a query string.
  def query(nil), do: {:ok, ""}

  def query(value) when is_binary(value) do
    value
    |> String.trim_leading("?")
    |> URI.decode_query()
    |> query()
  rescue
    _bad -> invalid("query", "is not a URL query")
  end

  def query(value) when is_map(value) do
    value
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.drop(@dropped)
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.sort()
    |> Enum.map(fn
      {k, v} when is_list(v) -> {k, Enum.map_join(v, ",", &to_string/1)}
      {k, v} -> {k, to_string(v)}
    end)
    |> URI.encode_query()
    |> then(&{:ok, &1})
  end

  def query(_value), do: invalid("query", "is not a URL query")

  defp columns(_screen, nil), do: {:ok, []}

  defp columns(:tracker, columns) when is_list(columns) do
    columns = Enum.map(columns, &to_string/1)

    cond do
      not Enum.all?(columns, &(&1 in Vocabulary.tracker_columns())) ->
        invalid("columns", "has a value that is not a Tracker column")

      Enum.uniq(columns) != columns ->
        invalid("columns", "names a column twice")

      true ->
        {:ok, Enum.map(columns, &String.to_atom/1)}
    end
  end

  defp columns(_screen, []), do: {:ok, []}
  defp columns(:tracker, _columns), do: invalid("columns", "is a list of Tracker columns")
  defp columns(_screen, _columns), do: invalid("columns", "are the Tracker's alone")

  defp position(value) when is_integer(value) and value >= 0, do: {:ok, %{position: value}}
  defp position(_value), do: invalid("position", "is a whole number, 0 or more")

  defp answer({:ok, view}), do: {:ok, view(view)}
  defp answer(error), do: error

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
