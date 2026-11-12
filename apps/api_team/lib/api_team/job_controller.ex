defmodule ApiTeam.JobController do
  @moduledoc """
  The job pool in the console (AQ-03 §7): the list, the check, a job made,
  read and edited, its platform details, its verbs (close and reopen carry
  the status the client saw, `from`), merge, its suggestions and
  dismissals. Every write answers the sheet in §7.1's shape.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.JobsJSON
  alias Core.Clock
  alias Core.Jobs
  alias Core.Jobs.{Act, Check, Pool}

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Pool.list(conn.assigns.scope, params, Clock.now()),
         do: json(conn, JobsJSON.page(page))
  end

  def check(conn, params) do
    with {:ok, answer} <- Check.run(conn.assigns.scope, params, Clock.now()),
         do: json(conn, JobsJSON.check(answer))
  end

  def create(conn, params) do
    with {:ok, sheet} <- Jobs.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(JobsJSON.sheet(sheet))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, sheet} <- Jobs.get(conn.assigns.scope, id, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, sheet} <-
           Jobs.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def platform_details(conn, %{"id" => id} = params) do
    with {:ok, sheet} <-
           Jobs.put_platform_details(
             conn.assigns.scope,
             id,
             Map.delete(params, "id"),
             Clock.now()
           ),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def close(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- Act.close(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def reopen(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- Act.reopen(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, sheet} <- Act.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def unarchive(conn, %{"id" => id}) do
    with {:ok, sheet} <- Act.unarchive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def merge(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- Act.merge(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def suggestions(conn, %{"id" => id}) do
    with {:ok, list} <- Jobs.suggestions(conn.assigns.scope, id, Clock.now()),
         do: json(conn, JobsJSON.suggestions(list))
  end

  def dismiss(conn, %{"id" => id} = params) do
    with {:ok, sheet} <- Act.dismiss(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end

  def undismiss(conn, %{"id" => id, "profile_id" => profile_id}) do
    with {:ok, sheet} <- Act.undismiss(conn.assigns.scope, id, profile_id, Clock.now()),
         do: json(conn, JobsJSON.sheet(sheet))
  end
end
