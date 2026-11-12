defmodule ApiExt.LeadController do
  @moduledoc """
  *Save for later*, *I applied* and *Apply again…* (AQ-05 §10.3, §11.4),
  each answering `written`: 201 with `answer: "created"`; 200 with
  `"applied"` (a To do lead applied, or applied again) or `"replayed"` (a
  retry of a write that landed). `Core.Ingest.Extension` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Clock
  alias Core.Ingest.Extension

  action_fallback ApiShared.FallbackController

  def save(conn, params),
    do: written(conn, Extension.save(conn.assigns.scope, params, Clock.now()))

  def applied(conn, params),
    do: written(conn, Extension.applied(conn.assigns.scope, params, Clock.now()))

  def apply_again(conn, %{"id" => id} = params) do
    written(
      conn,
      Extension.apply_again(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now())
    )
  end

  defp written(conn, {:ok, {:created, written}}),
    do: conn |> put_status(:created) |> json(ExtensionJSON.written(written))

  defp written(conn, {:ok, {_applied_or_replayed, written}}),
    do: json(conn, ExtensionJSON.written(written))

  defp written(_conn, error), do: error
end
