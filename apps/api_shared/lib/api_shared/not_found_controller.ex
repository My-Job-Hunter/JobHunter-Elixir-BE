defmodule ApiShared.NotFoundController do
  @moduledoc """
  The answer to a path no route matches (`ApiShared.Routes.not_found_routes/0`).

  It decides nothing itself: it returns `{:error, :not_found}` and the fallback
  shapes it, so the body and the status come from the one place that decides
  them.
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback ApiShared.FallbackController

  def show(_conn, _params), do: {:error, :not_found}
end
