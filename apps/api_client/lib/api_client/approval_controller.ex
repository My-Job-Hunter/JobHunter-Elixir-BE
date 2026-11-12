defmodule ApiClient.ApprovalController do
  @moduledoc """
  Approvals in the portal (AQ-07 §11.2, §11.4): what waits on the customer
  (`GET /approvals?tab=waiting|all`), the nav's count, a lead's approvals
  (its Approvals tab, a bare list), the sheet, *Approve* · *Request
  changes* · *Reject* (200), and the comments (201 to add, 204 to
  delete). The scope is pinned to the customer; `Core.Approvals` cuts
  their view (`team: null`, staff by first name when the team shows names,
  `can` only `decide` and `comment`).
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ApprovalsJSON, as: JSON
  alias Core.Approvals
  alias Core.Approvals.{Act, Comments}
  alias Core.Clock

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Approvals.list(conn.assigns.scope, params, Clock.now()),
         do: json(conn, JSON.page(page))
  end

  def count(conn, params) do
    with {:ok, count} <- Approvals.count(conn.assigns.scope, params),
         do: json(conn, JSON.count(count))
  end

  def for_lead(conn, %{"id" => id}) do
    with {:ok, rows} <- Approvals.for_lead(conn.assigns.scope, id, Clock.now()),
         do: json(conn, Enum.map(rows, &JSON.row/1))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, a} <- Approvals.get(conn.assigns.scope, id, Clock.now()),
         do: json(conn, JSON.approval(a))
  end

  def decide(conn, %{"id" => id} = params) do
    with {:ok, a} <- Act.decide(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()),
         do: json(conn, JSON.approval(a))
  end

  def comments(conn, %{"id" => id}) do
    with {:ok, list} <- Comments.list(conn.assigns.scope, id),
         do: json(conn, Enum.map(list, &JSON.comment/1))
  end

  def comment(conn, %{"id" => id} = params) do
    with {:ok, c} <-
           Comments.create(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()) do
      conn |> put_status(:created) |> json(JSON.comment(c))
    end
  end

  def delete_comment(conn, %{"id" => id}) do
    with :ok <- Comments.delete(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
