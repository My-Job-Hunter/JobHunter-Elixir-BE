defmodule ApiShared.MediaController do
  @moduledoc """
  The three-step upload (AQ-01 §4.1, §6.1), shared by every app at its own
  prefix; **never a static plug**, every read goes through here.

      1. POST /media                 → the row, with upload: {url, method, headers}
      2. PUT  /media/:id/blob        → the bytes (204)
      3. POST /media/:id/confirm     → the file, uploaded

  `GET /media/:id?t=` serves a confirmed file to whoever carries the
  hour-long signed `t`, cached privately: a shared cache in front of a
  signed link is the same leak with extra steps.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Media
  alias Core.Storage

  action_fallback ApiShared.FallbackController

  def create(conn, params) do
    with {:ok, media, target} <- Media.create(conn.assigns.scope, params, conn.request_path) do
      conn
      |> put_status(:created)
      |> json(Map.put(Media.view(media), :upload, target))
    end
  end

  def blob(conn, %{"id" => id}) do
    with {:ok, body, conn} <- read_all(conn),
         :ok <- Media.store(conn.assigns.scope, id, body) do
      send_resp(conn, :no_content, "")
    end
  end

  def confirm(conn, %{"id" => id} = params) do
    with {:ok, media} <- Media.confirm(conn.assigns.scope, id, params, Clock.now()) do
      json(conn, Media.view(media))
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, media, bytes} <- Media.read(id, params["t"]) do
      conn
      |> put_resp_content_type(media.content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_header("content-disposition", disposition(media))
      |> send_resp(200, bytes)
    end
  end

  # A document downloads under its own name; a photo renders inline.
  defp disposition(%{media_kind: :photo}), do: "inline"
  defp disposition(%{original_filename: nil}), do: "attachment"

  defp disposition(%{original_filename: name}),
    do: ~s(attachment; filename="#{String.replace(name, ~s("), "")}")

  # The bytes as they are, under the biggest cap; the exact cap is checked by
  # `Core.Media.store/3` once the row says which kind it is.
  defp read_all(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} ->
        {:ok, acc <> chunk, conn}

      {:more, chunk, conn} ->
        accumulated = acc <> chunk
        cap = Storage.max_bytes(:document)

        if byte_size(accumulated) > cap,
          do: {:error, {:file_too_large, cap}},
          else: read_all(conn, accumulated)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
