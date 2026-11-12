defmodule ApiTeam.TaskController do
  @moduledoc """
  A task in the console (AQ-02 §7.2): made, read, edited, its verbs (each
  carrying the state the client saw, `from`), archive and unarchive, a
  draft's delete, its people, its history and the relation picker's search.
  Every write answers the sheet (204 when the write took the task out of
  the caller's sight).
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.TasksJSON
  alias Core.Clock
  alias Core.Tasks
  alias Core.Tasks.{Act, People}

  action_fallback ApiShared.FallbackController

  def search(conn, params) do
    with {:ok, tasks} <- Tasks.search(conn.assigns.scope, params["q"]), do: json(conn, tasks)
  end

  def create(conn, params) do
    with {:ok, sheet} <- Tasks.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> TasksJSON.send_sheet(sheet)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, sheet} <- Tasks.get(conn.assigns.scope, id, Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, sheet} <-
           Tasks.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Act.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  for verb <- [:start, :move, :hold, :resume, :done, :reopen, :close] do
    def unquote(verb)(conn, %{"id" => id} = params) do
      with {:ok, sheet} <- Act.run(conn.assigns.scope, unquote(verb), id, params, Clock.now()),
           do: TasksJSON.send_sheet(conn, sheet)
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, sheet} <- Act.archive(conn.assigns.scope, id, Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def unarchive(conn, %{"id" => id}) do
    with {:ok, sheet} <- Act.unarchive(conn.assigns.scope, id, Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def assignees(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- People.put_assignees(conn.assigns.scope, id, params, Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def watch(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- People.watch(conn.assigns.scope, id, params["on"], Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def mute(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- People.mute(conn.assigns.scope, id, params["on"], Clock.now()),
         do: TasksJSON.send_sheet(conn, sheet)
  end

  def history(conn, %{"id" => id}) do
    with {:ok, groups} <- Tasks.history(conn.assigns.scope, id),
         do: json(conn, TasksJSON.history(groups))
  end
end
