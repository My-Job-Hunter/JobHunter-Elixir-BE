defmodule ApiExt.JobController do
  @moduledoc """
  The page's job (AQ-05 §10, §11.1): `GET /jobs/lookup?url&team_id&profile_id?`
  (`lookup`) and `POST /jobs/capture {team_id, url, fields}` (200).
  `Core.Ingest.Extension` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Clock
  alias Core.Ingest.Extension

  action_fallback ApiShared.FallbackController

  def lookup(conn, params) do
    with {:ok, lookup} <- Extension.lookup(conn.assigns.scope, params, Clock.now()),
         do: json(conn, ExtensionJSON.lookup(lookup))
  end

  def capture(conn, params) do
    with {:ok, capture} <- Extension.capture(conn.assigns.scope, params, Clock.now()),
         do: json(conn, ExtensionJSON.capture(capture))
  end
end
