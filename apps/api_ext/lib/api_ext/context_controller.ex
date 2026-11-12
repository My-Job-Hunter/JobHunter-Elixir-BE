defmodule ApiExt.ContextController do
  @moduledoc "`GET /context?site&identity` (AQ-05 §8): `Core.Extension.Context` decides."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ExtensionJSON
  alias Core.Clock
  alias Core.Extension.Context

  action_fallback ApiShared.FallbackController

  def show(conn, params) do
    with {:ok, context} <- Context.get(conn.assigns.scope, params, Clock.now()),
         do: json(conn, ExtensionJSON.context(context))
  end
end
