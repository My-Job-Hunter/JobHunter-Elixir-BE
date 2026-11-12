defmodule ApiTeam.CompanyController do
  @moduledoc """
  Companies in the console (AQ-03 §7): the job form's picker, the card and
  its edit sheet. Every company answer is the card of §7.1.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.JobsJSON
  alias Core.Clock
  alias Core.Companies

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, list} <- Companies.search(conn.assigns.scope, params["q"]),
         do: json(conn, JobsJSON.companies(list))
  end

  def create(conn, params) do
    with {:ok, company} <- Companies.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(JobsJSON.company(company))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, company} <- Companies.get(conn.assigns.scope, id),
         do: json(conn, JobsJSON.company(company))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, company} <-
           Companies.update(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, JobsJSON.company(company))
  end
end
