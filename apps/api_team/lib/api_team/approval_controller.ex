defmodule ApiTeam.ApprovalController do
  @moduledoc """
  Approvals in the console (AQ-07 §11.1, §11.4): the page (`GET
  /approvals?team_id&tab&kind&customer_id&state&due&cursor`), the nav's
  count, a lead's approvals (a bare list), *Request approval…* (201), the
  sheet and its edit (a draft), the verbs (submit, decide, revise,
  withdraw, *Recorded as sent*: 200), the comments (201 to add, 204 to
  delete) and a customer's policies (`GET`, `PUT` 200, `DELETE` 204).
  `Core.Approvals` decides; `ApiShared.ApprovalsJSON` lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ApprovalsJSON, as: JSON
  alias Core.Approvals
  alias Core.Approvals.{Act, Comments, Policies}
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

  def create(conn, params) do
    with {:ok, a} <- Approvals.draft(conn.assigns.scope, params, Clock.now()) do
      conn |> put_status(:created) |> json(JSON.approval(a))
    end
  end

  def show(conn, %{"id" => id}),
    do: approval(conn, Approvals.get(conn.assigns.scope, id, Clock.now()))

  def update(conn, %{"id" => id} = params),
    do:
      approval(
        conn,
        Approvals.edit(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now())
      )

  def submit(conn, %{"id" => id}),
    do: approval(conn, Act.submit(conn.assigns.scope, id, Clock.now()))

  def withdraw(conn, %{"id" => id}),
    do: approval(conn, Act.withdraw(conn.assigns.scope, id, Clock.now()))

  def decide(conn, %{"id" => id} = params),
    do: approval(conn, Act.decide(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()))

  def revise(conn, %{"id" => id} = params),
    do: approval(conn, Act.revise(conn.assigns.scope, id, Map.delete(params, "id"), Clock.now()))

  def sent(conn, %{"id" => id}), do: approval(conn, Act.sent(conn.assigns.scope, id, Clock.now()))

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

  def policies(conn, %{"id" => id}) do
    with {:ok, rows} <- Policies.list(conn.assigns.scope, id),
         do: json(conn, Enum.map(rows, &JSON.policy/1))
  end

  def put_policy(conn, %{"id" => id, "kind" => kind} = params) do
    body = Map.drop(params, ["id", "kind"])

    with {:ok, row} <- Policies.put(conn.assigns.scope, id, kind, body, Clock.now()),
         do: json(conn, JSON.policy(row))
  end

  def delete_policy(conn, %{"id" => id, "kind" => kind}) do
    with :ok <- Policies.reset(conn.assigns.scope, id, kind, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  defp approval(conn, {:ok, a}), do: json(conn, JSON.approval(a))
  defp approval(_conn, error), do: error
end
