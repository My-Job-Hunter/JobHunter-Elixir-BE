defmodule Api.InboundController do
  @moduledoc """
  Forwarded mail in (AQ-09 §6.2, §6.3, §11.4), thin: the provider's
  webhook and the dev route hand the body to `Core.Inbound`, as the
  system.

  - `POST /inbound/email`: Postmark's JSON, trusted by basic auth compared
    in constant time — 401 with no body for a wrong pair, 503
    `inbound_off` with no password configured — answered 200 `{outcome}`
    for every mail accepted, an unknown address or an unreadable mail
    included; 413 over 30 MB (`Api.Endpoint`); 429 when one address
    floods.
  - `POST /dev/inbound {to, eml}` (dev servers only): 200 `{outcome,
    message_id, conversation_id}`, the ids `null` unless it landed.
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Clock
  alias Core.Inbound
  alias Data.Scope

  action_fallback ApiShared.FallbackController

  def email(conn, params) do
    {user, password} = credentials(conn)

    with :ok <- Inbound.authorise(user, password),
         {:ok, answer} <- Inbound.postmark(Scope.system(), params, size(conn), Clock.now()),
         do: json(conn, %{outcome: answer.outcome})
  end

  def dev(conn, params) do
    with {:ok, answer} <- Inbound.dev(Scope.system(), params, Clock.now()),
         do: json(conn, Map.take(answer, [:outcome, :message_id, :conversation_id]))
  end

  @doc """
  A webhook body over the cap (`Api.Endpoint.parse/2`): with the right
  credentials it is logged `too_large`; either way 413 `file_too_large`,
  and the conn halted.
  """
  def too_large(conn, bytes) do
    {user, password} = credentials(conn)

    result =
      case Inbound.authorise(user, password) do
        :ok ->
          :ok = Inbound.too_large(Scope.system(), bytes, Clock.now())
          {:error, {:file_too_large, Inbound.max_bytes()}}

        refused ->
          refused
      end

    conn
    |> ApiShared.FallbackController.call(result)
    |> Plug.Conn.halt()
  end

  defp credentials(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {user, password} -> {user, password}
      :error -> {nil, nil}
    end
  end

  defp size(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [length | _rest] -> String.to_integer(length)
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end
end
