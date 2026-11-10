defmodule ApiClient.SkillController do
  @moduledoc """
  The skills vocabulary, read-only (not in JH-01 §6.3, added because the
  portal's `PUT /profiles/:id/skills` needs the ids to pick from).
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Customers.Skills

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, skills} <- Skills.list(conn.assigns.scope, params),
         do: json(conn, Enum.map(skills, &CustomersJSON.skill/1))
  end
end
