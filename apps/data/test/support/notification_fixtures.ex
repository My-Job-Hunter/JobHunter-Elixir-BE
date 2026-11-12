defmodule Data.Fixtures.Notifications do
  @moduledoc """
  The notifications' fixtures, reached through `Data.Fixtures`: P2's
  `notification_fixture/3`, and P8's (AQ-08 §14)
  `push_subscription_fixture/2`, `preference_fixture/3` and
  `delivery_fixture/2`. Like the rest they write through `Data.*`, so a
  `notifire` test (which cannot call `core`) builds a ledger row by hand.
  """

  alias Data.Notifications
  alias Data.Notifications.{Deliveries, Preference, Preferences, PushSubscriptions}
  alias Data.Scope

  @doc "A notification for `user` (kind `tasks.assigned` unless said), in `organisation`."
  def notification_fixture(organisation, user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, notification} =
      Notifications.ensure(
        Scope.system(organisation),
        Enum.into(attrs, %{
          user_id: user.id,
          notification_kind_key: "tasks.assigned",
          title: "Notification #{n}",
          dedupe_key: "fixture:#{n}"
        })
      )

    notification
  end

  @doc """
  A browser with push turned on for `user`: `app` `:team` unless said, a
  fresh `https://` endpoint and a real P-256 key, so a push encrypts.
  """
  def push_subscription_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)
    n = System.unique_integer([:positive])

    {:ok, subscription} =
      PushSubscriptions.upsert(
        user.id,
        Map.get(attrs, :app, :team),
        %{
          endpoint: Map.get(attrs, :endpoint, "https://push.example.com/send/#{n}"),
          p256dh: Map.get(attrs, :p256dh, Base.url_encode64(public, padding: false)),
          auth:
            Map.get(
              attrs,
              :auth,
              Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
            ),
          user_agent: Map.get(attrs, :user_agent, "Chrome on macOS")
        },
        Map.get(attrs, :at, DateTime.utc_now())
      )

    subscription
  end

  @doc "`user`'s switches for `group_key`: all on, then `switches` (`%{push: false}`)."
  def preference_fixture(user, group_key, switches \\ %{}) do
    all = Map.merge(Preference.switches(nil), Map.new(switches))
    {:ok, preference} = Preferences.put(user.id, group_key, all, DateTime.utc_now())
    preference
  end

  @doc """
  A ledger row for `notification`: `channel` `:email` unless said, due
  `deliver_after` (now), with `ics` when given. The planning is `core`'s;
  this writes the row as it would.
  """
  def delivery_fixture(notification, attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :now, DateTime.utc_now())

    [row] =
      Deliveries.insert_planned(
        notification,
        [
          %{
            channel: Map.get(attrs, :channel, :email),
            deliver_after: Map.get(attrs, :deliver_after, now),
            deferred: Map.get(attrs, :deferred, false)
          }
        ],
        Map.get(attrs, :ics),
        now
      )

    row
  end
end
