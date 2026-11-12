defmodule ApiTeam.SkillController do
  @moduledoc "The skills vocabulary (AQ-01 §6.2, QP1-4)."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers.Skills

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, skills} <- Skills.list(conn.assigns.scope, params),
         do: json(conn, Enum.map(skills, &CustomersJSON.skill/1))
  end

  def create(conn, params) do
    with {:ok, skill} <- Skills.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.skill(skill))
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, skill} <- Skills.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.skill(skill))
  end
end
