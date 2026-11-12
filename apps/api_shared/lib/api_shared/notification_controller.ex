defmodule ApiShared.NotificationController do
  @moduledoc """
  The bell (AQ-02 §7.1), served by both apps: a person's own notifications,
  their unread count, the groups for the chips, and marking read. Shapes
  are `Core.Notifications`' (§7.6): the page `{items, next_cursor}`, the
  count `{unread}`, the groups `[{key, label}]`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Notifications

  action_fallback ApiShared.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Notifications.page(conn.assigns.scope, params), do: json(conn, page)
  end

  def count(conn, _params) do
    with {:ok, count} <- Notifications.count(conn.assigns.scope), do: json(conn, count)
  end

  def groups(conn, _params) do
    with {:ok, groups} <- Notifications.groups(conn.assigns.scope), do: json(conn, groups)
  end

  def read(conn, %{"id" => id}) do
    with :ok <- Notifications.read(conn.assigns.scope, id, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end

  def read_all(conn, _params) do
    with :ok <- Notifications.read_all(conn.assigns.scope, Clock.now()),
         do: send_resp(conn, :no_content, "")
  end
end
