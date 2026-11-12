defmodule Core.Plugs.RateLimit do
  @moduledoc """
  Per-caller rate limiting. **The backstop on anything people write that
  others read**, such as a lead's notes or a task's comments, and on anything
  that sends mail to an address somebody typed. A form with no limit is a
  form with a script posting to it.

  ## Keying

  By **user id** when signed in, by **IP** otherwise. That order matters: a
  BD team behind one office address is several real people, and a pure per-IP
  limit throttles the whole team for one member's posting. Place this
  after the authenticate plug so `current_user` is set.

  `by: :device` keys on the connected extension instead
  (`conn.assigns.device`, AQ-05 §11.4: 120 a minute per device), so one
  person's two browsers have a budget each.

  ## Failing open

  A backend error allows the request. **A rate limiter must never 500 the
  pipeline it guards** — the failure it is preventing is spam, and the failure
  it would cause is an outage.

  ## Configuration

      config :core, Core.Plugs.RateLimit, enabled: true

  Disabled in tests, because a suite that hammers an endpoint is the point of
  the suite. There is a test that turns it on and asserts it bites.

  ## Proxy note

  Behind a load balancer the real client is in `x-forwarded-for`; the
  left-most entry wins, falling back to the socket peer. XFF is spoofable, so
  this is a **backstop, not an auth boundary**.
  """

  @behaviour Plug

  import Plug.Conn

  alias Core.RateLimiter

  require Logger

  @default_limit 60
  @default_scale_ms 60_000

  @impl Plug
  def init(opts) do
    %{
      name: Keyword.fetch!(opts, :name),
      limit: Keyword.get(opts, :limit, @default_limit),
      scale_ms: Keyword.get(opts, :scale_ms, @default_scale_ms),
      by: Keyword.get(opts, :by, :caller)
    }
  end

  @impl Plug
  def call(conn, %{name: name, limit: limit, scale_ms: scale_ms} = opts) do
    case check("#{name}:#{caller_id(conn, Map.get(opts, :by, :caller))}", scale_ms, limit) do
      :allow -> conn
      {:deny, retry_after_ms} -> reject(conn, retry_after_ms)
    end
  end

  @doc """
  A bucket check that is not a plug.

  For limits a pipeline cannot express — "five posts an hour" is per action,
  not per request, so it belongs at the call site rather than on the route.
  """
  @spec check(String.t(), non_neg_integer(), non_neg_integer()) :: :allow | {:deny, integer()}
  def check(key, scale_ms, limit) do
    if enabled?() do
      case RateLimiter.hit(key, scale_ms, limit) do
        {:allow, _count} -> :allow
        {:deny, retry_after_ms} -> {:deny, retry_after_ms}
      end
    else
      :allow
    end
  rescue
    # **Fails open.** Hammer 7 raises rather than returning an error tuple —
    # a missing table, a supervisor not yet up — and the failure this guards
    # against is spam while the failure it would cause is an outage.
    error ->
      Logger.warning("rate limiter unavailable, allowing request: #{inspect(error)}")
      :allow
  end

  @doc """
  The client's address, preferring the left-most `x-forwarded-for` entry.

  Public so a call-site throttle keys on the *same* address as the plug —
  behind a load balancer `conn.remote_ip` is the proxy, and keying on it
  collapses every caller into one bucket.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _rest] -> forwarded |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp enabled?, do: :core |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)

  # A connected extension has its own budget (AQ-05 §11.4).
  defp caller_id(%{assigns: %{device: %{id: id}}}, :device) when is_binary(id), do: "device:#{id}"
  defp caller_id(conn, _by), do: caller_id(conn)

  # Signed-in callers get their own budget; anonymous callers share by address.
  defp caller_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} when is_binary(id) -> "user:#{id}"
      _anonymous -> "ip:#{client_ip(conn)}"
    end
  end

  defp reject(conn, retry_after_ms) do
    seconds = retry_after_ms |> div(1000) |> max(1)

    body =
      Jason.encode!(%{
        error: %{
          code: "rate_limited",
          message: "Too many attempts. Wait a moment and try again.",
          details: %{retry_after_seconds: seconds}
        }
      })

    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end
end
