defmodule ApiTeam.PipelineController do
  @moduledoc """
  Settings › Pipelines (AQ-04A §8.1, §9): the live version of both
  pipelines, or of one; `PUT` writes a new version and answers it.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.LeadsJSON
  alias Core.Clock
  alias Core.Leads.Pipelines

  action_fallback ApiShared.FallbackController

  def index(conn, _params) do
    with {:ok, list} <- Pipelines.list(conn.assigns.scope),
         do: json(conn, Enum.map(list, &LeadsJSON.pipeline/1))
  end

  def show(conn, %{"key" => key}) do
    with {:ok, pipeline} <- Pipelines.get(conn.assigns.scope, key),
         do: json(conn, LeadsJSON.pipeline(pipeline))
  end

  def update(conn, %{"key" => key} = params) do
    with {:ok, pipeline} <- Pipelines.save(conn.assigns.scope, key, params, Clock.now()),
         do: json(conn, LeadsJSON.pipeline(pipeline))
  end
end
