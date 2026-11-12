defmodule Core.Notifications.Push do
  @moduledoc """
  Push on a browser (AQ-08 §7.6, §11.4, QP8-14; mCart's
  `ApiShared.PushController`), **each person their own**: the server's
  public key and the person's browsers, a browser turned on or taken off,
  and *Send a test*. The push itself goes out from `notifire`'s sweep.

  - **`app` is the surface's** (`/team/v1` → `team`, `/client/v1` →
    `client`), never the body's.
  - **A known endpoint moves** to this person and app: a shared computer
    never pushes one person's notices to the next.
  - **The test goes through the pipeline**: `account.push_test`, which
    passes quiet hours, so it proves the real path.
  - **Without VAPID keys push is off** (`config :notifire, :web_push`, read
    as config, never as a call): the page says `public_key: null`.
  """

  alias Core.Notifications
  alias Data.Notifications.PushSubscriptions
  alias Data.Scope

  @lost "This browser's subscription didn't come through."

  @doc "`GET /me/push`: **push page**, `{public_key, devices}`, the person's own, newest first, every app."
  @spec page(Scope.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope) do
    with {:ok, user_id} <- me(scope), do: {:ok, page_for(user_id)}
  end

  @doc """
  `POST /me/push` from `app`: `{endpoint, keys: {p256dh, auth},
  user_agent?}` → **push page**. 422 on `endpoint` for a missing key or an
  endpoint that isn't `https://`.
  """
  @spec subscribe(Scope.t(), atom(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def subscribe(%Scope{} = scope, app, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    keys = if is_map(params["keys"]), do: params["keys"], else: %{}

    attrs = %{
      endpoint: string(params["endpoint"]),
      p256dh: string(keys["p256dh"]),
      auth: string(keys["auth"]),
      user_agent: string(params["user_agent"])
    }

    with {:ok, user_id} <- me(scope) do
      case PushSubscriptions.upsert(user_id, app, attrs, now) do
        {:ok, _subscription} -> {:ok, page_for(user_id)}
        {:error, :invalid} -> {:error, {:invalid, %{"endpoint" => [@lost]}}}
      end
    end
  end

  @doc "`DELETE /me/push` with `{endpoint}`: **push page**; an endpoint not the person's is no error."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def remove(%Scope{} = scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, user_id} <- me(scope) do
      :ok = PushSubscriptions.remove(user_id, string(params["endpoint"]))
      {:ok, page_for(user_id)}
    end
  end

  @doc """
  `POST /me/push/test`: ensures `account.push_test` keyed
  `push_test:<user>:<now in ms>`, through the pipeline.
  """
  @spec test(Scope.t(), DateTime.t()) :: :ok | {:error, term()}
  def test(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, user_id} <- me(scope),
         {:ok, row} <-
           Notifications.ensure(
             scope,
             %{
               user_id: user_id,
               notification_kind_key: "account.push_test",
               title: "Push works. AutoQare can reach this browser.",
               link_path: "/notifications",
               dedupe_key: "push_test:#{user_id}:#{DateTime.to_unix(now, :millisecond)}"
             },
             now
           ) do
      if row.is_new, do: Notifications.created([row])
      :ok
    end
  end

  @doc "The public key a browser subscribes with (base64url), or `nil` when push is off."
  @spec public_key() :: String.t() | nil
  def public_key do
    keys = Application.get_env(:notifire, :web_push) || []
    if keys[:public_key] && keys[:private_key], do: keys[:public_key]
  end

  defp page_for(user_id) do
    %{
      public_key: public_key(),
      devices:
        for s <- PushSubscriptions.for_user(user_id) do
          %{
            id: s.id,
            app: s.app,
            endpoint: s.endpoint,
            user_agent: s.user_agent,
            last_used_at: s.last_used_at,
            failed_at: s.failed_at,
            inserted_at: s.inserted_at
          }
        end
    }
  end

  defp string(value) when is_binary(value), do: Utils.presence(value)
  defp string(_value), do: nil

  defp me(scope) do
    case Scope.user_id(scope) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end
end
