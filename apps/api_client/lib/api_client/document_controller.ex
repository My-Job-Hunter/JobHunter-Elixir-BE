defmodule ApiClient.DocumentController do
  @moduledoc "The customer's own documents (AQ-01 §6.3): upload, new version, default, archive."

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.CustomersJSON
  alias Core.Clock
  alias Core.Customers.Documents

  action_fallback ApiShared.FallbackController

  def index(conn, %{"id" => profile_id}) do
    with {:ok, documents} <- Documents.list(conn.assigns.scope, profile_id),
         do: json(conn, Enum.map(documents, &CustomersJSON.document/1))
  end

  def create(conn, %{"id" => profile_id} = params) do
    with {:ok, document} <- Documents.create(conn.assigns.scope, profile_id, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.document(document))
    end
  end

  def new_version(conn, %{"id" => id} = params) do
    with {:ok, document} <- Documents.new_version(conn.assigns.scope, id, params, Clock.now()) do
      conn |> put_status(:created) |> json(CustomersJSON.document(document))
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, document} <- Documents.archive(conn.assigns.scope, id, Clock.now()),
         do: json(conn, CustomersJSON.document(document))
  end

  def put_default(conn, %{"id" => profile_id} = params) do
    with {:ok, profile} <-
           Documents.put_default(conn.assigns.scope, profile_id, params["document_id"] || ""),
         do: json(conn, CustomersJSON.profile(profile))
  end
end
