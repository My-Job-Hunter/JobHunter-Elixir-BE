defmodule ApiTeam.CustomerController do
  @moduledoc "Customers, their teams, their portal invitation and their notes (JH-01 §6.2)."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers
  alias Core.Customers.Notes

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, customers} <- Customers.list(conn.assigns.scope, params) do
      json(conn, Enum.map(customers, &CustomersJSON.customer/1))
    end
  end

  def create(conn, params) do
    with {:ok, customer} <- Customers.create(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.customer(customer))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, customer} <- Customers.get(conn.assigns.scope, id),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, customer} <- Customers.update(conn.assigns.scope, id, params),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def change_status(conn, %{"id" => id} = params) do
    with {:ok, customer} <-
           Customers.change_status(conn.assigns.scope, id, params["status"], Clock.now()),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def assign_team(conn, %{"id" => id} = params) do
    with {:ok, customer} <-
           Customers.assign_team(conn.assigns.scope, id, params["team_id"], Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.customer(customer))
    end
  end

  def remove_team(conn, %{"id" => id, "team_id" => team_id}) do
    with {:ok, customer} <- Customers.remove_team(conn.assigns.scope, id, team_id, Clock.now()),
         do: json(conn, CustomersJSON.customer(customer))
  end

  def invite(conn, %{"id" => id}) do
    with {:ok, invitation, status} <- Customers.invite(conn.assigns.scope, id, Clock.now()) do
      conn
      |> put_status(if(status == :issued, do: :created, else: :ok))
      |> put_view(json: ApiTeam.InvitationJSON)
      |> render(:show, invitation: invitation, now: Clock.now())
    end
  end

  # ── Notes ───────────────────────────────────────────────────────────────────

  def notes(conn, %{"id" => id}) do
    with {:ok, notes} <- Notes.list(conn.assigns.scope, id),
         do: json(conn, Enum.map(notes, &CustomersJSON.note/1))
  end

  def create_note(conn, %{"id" => id} = params) do
    with {:ok, note} <- Notes.create(conn.assigns.scope, id, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.note(note))
    end
  end

  def update_note(conn, %{"id" => id} = params) do
    with {:ok, note} <- Notes.update(conn.assigns.scope, id, params, Clock.now()),
         do: json(conn, CustomersJSON.note(note))
  end

  def delete_note(conn, %{"id" => id}) do
    with :ok <- Notes.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
