defmodule ApiExt.ConfigController do
  @moduledoc """
  `GET /config?site` (AQ-05 §6.4, QP5-21): the site's live selector
  document, byte for byte as published, with `ETag` its SHA-256 (quoted)
  and `x-aq-config-version` its version, on the 200 and the 304 alike;
  `If-None-Match` naming the ETag answers `304` with no body.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Extension.Configs

  action_fallback ApiShared.FallbackController

  def show(conn, params) do
    with {:ok, config} <- Configs.live(conn.assigns.scope, params["site"]) do
      # The version rides on both answers, so a miss names the config it
      # was read with (AQ-05 §5.2).
      conn =
        conn
        |> put_resp_header("etag", ~s("#{config.sha256}"))
        |> put_resp_header("x-aq-config-version", to_string(config.version))

      if fresh?(conn, config.sha256) do
        send_resp(conn, :not_modified, "")
      else
        conn |> put_resp_content_type("application/json") |> send_resp(:ok, config.body)
      end
    end
  end

  # `If-None-Match: "<sha>"`, weak or strong, alone or in a list.
  defp fresh?(conn, sha) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "") |> String.trim("\"")))
    |> Enum.any?(&(&1 == sha or &1 == "*"))
  end
end
