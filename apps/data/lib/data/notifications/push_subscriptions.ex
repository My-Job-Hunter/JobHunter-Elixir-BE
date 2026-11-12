defmodule Data.Notifications.PushSubscriptions do
  @moduledoc """
  The browsers that take Web Push for a person (AQ-08 §5, QP8-14; mCart's),
  storage only: one row per endpoint, the app it was made on, when it was
  last used and last failed. **A known endpoint moves** to whoever
  subscribes it next, with their app: the same browser, another person.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.PushSubscription
  alias Data.Repo

  @apps PushSubscription.apps()

  @doc """
  A browser's subscription, made or moved by its endpoint. `{:error,
  :invalid}` for an endpoint that isn't `https://`, a missing key or an
  unknown app.
  """
  @spec upsert(binary(), atom(), map(), DateTime.t()) ::
          {:ok, PushSubscription.t()} | {:error, :invalid}
  def upsert(
        user_id,
        app,
        %{endpoint: "https://" <> _ = endpoint, p256dh: p, auth: a} = s,
        %DateTime{} = now
      )
      when app in @apps and is_binary(p) and p != "" and is_binary(a) and a != "" do
    row = %{
      id: Uniq.UUID.uuid7(),
      user_id: user_id,
      app: app,
      endpoint: endpoint,
      p256dh: p,
      auth: a,
      user_agent: s[:user_agent] && String.slice(s.user_agent, 0, 255),
      inserted_at: usec(now),
      updated_at: usec(now)
    }

    Repo.insert_all(PushSubscription, [row],
      on_conflict:
        {:replace, [:user_id, :app, :p256dh, :auth, :user_agent, :updated_at, :failed_at]},
      conflict_target: [:endpoint]
    )

    {:ok, Repo.get_by!(PushSubscription, endpoint: endpoint)}
  end

  def upsert(_user_id, _app, _s, _now), do: {:error, :invalid}

  @doc "Takes a browser off (the person's own; another's endpoint is left alone)."
  @spec remove(binary(), String.t()) :: :ok
  def remove(user_id, endpoint) when is_binary(endpoint) do
    from(s in PushSubscription, where: s.user_id == ^user_id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def remove(_user_id, _endpoint), do: :ok

  @doc "A person's browsers on every app, newest first."
  @spec for_user(binary()) :: [PushSubscription.t()]
  def for_user(user_id), do: for_user(user_id, @apps)

  @doc "A person's browsers on the apps named, newest first."
  @spec for_user(binary(), [atom()]) :: [PushSubscription.t()]
  def for_user(user_id, apps) do
    from(s in PushSubscription,
      where: s.user_id == ^user_id and s.app in ^apps,
      order_by: [desc: s.inserted_at, desc: s.id]
    )
    |> Repo.all()
  end

  @doc "Whether the person has a browser turned on in `app`."
  @spec any?(binary(), atom()) :: boolean()
  def any?(user_id, app) do
    from(s in PushSubscription, where: s.user_id == ^user_id and s.app == ^app)
    |> Repo.exists?()
  end

  @doc "A browser the push service took (it is used), or refused for now (it failed)."
  @spec mark(binary(), :used | :failed, DateTime.t()) :: :ok
  def mark(id, :used, now),
    do: set(id, last_used_at: usec(now), failed_at: nil, updated_at: usec(now))

  def mark(id, :failed, now), do: set(id, failed_at: usec(now), updated_at: usec(now))

  @doc "A browser the push service says is gone (404, 410)."
  @spec delete(binary()) :: :ok
  def delete(id) do
    Repo.delete_all(from(s in PushSubscription, where: s.id == ^id))
    :ok
  end

  defp set(id, fields) do
    Repo.update_all(from(s in PushSubscription, where: s.id == ^id), set: fields)
    :ok
  end

  # The columns are `timestamptz` with microseconds, and Ecto dumps only a
  # `DateTime` of that precision: a rule's `~U[… 08:00:00Z]` is widened here.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end
