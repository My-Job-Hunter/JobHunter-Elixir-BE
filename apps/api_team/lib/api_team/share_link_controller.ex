defmodule ApiTeam.ShareLinkController do
  @moduledoc """
  Share links (AQ-03B §5.1): made and listed on a task, a job or a lead (AQ-04A QP4a-20), revoked by
  id, opened by token. `Core.ShareLinks` decides; `ApiTeam.ShareLinkJSON`
  lists the fields.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiTeam.ShareLinkJSON
  alias Core.Clock
  alias Core.ShareLinks

  action_fallback ApiShared.FallbackController

  def create_for_task(conn, %{"id" => id} = params), do: create(conn, {:task, id}, params)
  def create_for_job(conn, %{"id" => id} = params), do: create(conn, {:job, id}, params)
  def create_for_lead(conn, %{"id" => id} = params), do: create(conn, {:lead, id}, params)

  def index_for_task(conn, %{"id" => id}), do: index(conn, {:task, id})
  def index_for_job(conn, %{"id" => id}), do: index(conn, {:job, id})
  def index_for_lead(conn, %{"id" => id}), do: index(conn, {:lead, id})

  def revoke(conn, %{"id" => id}) do
    with {:ok, link} <- ShareLinks.revoke(conn.assigns.scope, id, Clock.now()),
         do: json(conn, ShareLinkJSON.link(link))
  end

  def show(conn, %{"token" => token}) do
    with {:ok, shared} <- ShareLinks.open(conn.assigns.scope, token, Clock.now()),
         do: json(conn, ShareLinkJSON.shared(shared))
  end

  defp create(conn, subject, params) do
    params = Map.delete(params, "id")

    with {:ok, made} <- ShareLinks.create(conn.assigns.scope, subject, params, Clock.now()) do
      conn |> put_status(:created) |> json(ShareLinkJSON.made(made))
    end
  end

  defp index(conn, subject) do
    with {:ok, links} <- ShareLinks.list(conn.assigns.scope, subject),
         do: json(conn, Enum.map(links, &ShareLinkJSON.link/1))
  end
end
