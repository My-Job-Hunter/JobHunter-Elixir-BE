defmodule ApiTeam.NotificationRoutesTest do
  @moduledoc """
  P8's console routes (AQ-08 §11.1–§11.4) through `ApiTeam.Router`: the
  settings and their 422s, push on this browser with `app` the surface's,
  *Send a test*, and delivery health with its 403.
  """

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    Map.put(c, :fiza_scope, scope_for(c.fiza))
  end

  test "GET /notifications/settings: the groups, quiet hours, the digest, the zone, what I have",
       c do
    conn = call(c.fiza, :get, "/v1/notifications/settings")
    assert conn.status == 200
    settings = body(conn)

    assert Enum.map(settings["groups"], & &1["key"]) ==
             ~w(tasks leads conversations meetings approvals account)

    assert %{
             "key" => "conversations",
             "label" => "Conversations",
             "can_disable" => true,
             "uses" => ["push", "email", "extension", "digest"],
             "push" => true,
             "email" => true,
             "extension" => true,
             "digest" => true
           } = Enum.at(settings["groups"], 2)

    assert settings["quiet_hours"] == %{"from" => nil, "to" => nil}
    assert settings["digest"] == %{"on" => true, "at" => "08:00"}
    assert settings["zone"] == "Asia/Karachi"
    assert settings["has"] == %{"push" => false, "extension" => false}
  end

  test "PUT /notifications/settings/groups/:key: a switch off; 404 and the 422s of §11.4", c do
    conn = call(c.fiza, :put, "/v1/notifications/settings/groups/approvals", %{email: false})
    assert conn.status == 200

    assert %{"email" => false, "push" => true} =
             Enum.find(body(conn)["groups"], &(&1["key"] == "approvals"))

    assert call(c.fiza, :put, "/v1/notifications/settings/groups/nope", %{push: false}).status ==
             404

    account = call(c.fiza, :put, "/v1/notifications/settings/groups/account", %{email: false})
    assert account.status == 422
    assert code(account) == "validation_failed"
    assert body(account)["error"]["details"] == %{"group" => ["These can't be turned off."]}

    unused = call(c.fiza, :put, "/v1/notifications/settings/groups/tasks", %{email: false})
    assert unused.status == 422
    assert body(unused)["error"]["details"] == %{"email" => ["This group doesn't use it."]}
  end

  test "/me/push: app is the console's whatever the body says; a known endpoint moves; the test is 202",
       c do
    sub = %{
      endpoint: "https://fcm.googleapis.com/fcm/send/abc",
      keys: %{p256dh: "BPkey", auth: "authsecret"},
      app: "client"
    }

    created = call(c.fiza, :post, "/v1/me/push", sub)
    assert created.status == 201

    assert %{
             "public_key" => "B" <> _,
             "devices" => [
               %{
                 "app" => "team",
                 "endpoint" => "https://fcm.googleapis.com/fcm/send/abc",
                 "user_agent" => nil,
                 "last_used_at" => nil,
                 "failed_at" => nil,
                 "inserted_at" => _,
                 "id" => _
               }
             ]
           } = body(created)

    # The same browser, Qasim signed in: it moves to him.
    assert call(c.qasim, :post, "/v1/me/push", sub).status == 201
    assert body(call(c.fiza, :get, "/v1/me/push"))["devices"] == []

    lost = call(c.fiza, :post, "/v1/me/push", %{endpoint: "http://x.example/a", keys: sub.keys})
    assert lost.status == 422

    assert body(lost)["error"]["details"] == %{
             "endpoint" => ["This browser's subscription didn't come through."]
           }

    tested = call(c.qasim, :post, "/v1/me/push/test")
    assert tested.status == 202
    assert body(tested) == %{}

    removed = call(c.qasim, :delete, "/v1/me/push", %{endpoint: sub.endpoint})
    assert removed.status == 200
    assert body(removed)["devices"] == []
  end

  test "GET /deliveries/health: the system admin's; anyone else 403 with the words", c do
    refused = call(c.hira, :get, "/v1/deliveries/health")
    assert refused.status == 403
    assert code(refused) == "forbidden"
    assert body(refused)["error"]["message"] == "Only the system admin can see delivery health."

    conn = call(c.dawud, :get, "/v1/deliveries/health")
    assert conn.status == 200

    assert %{"since" => _, "channels" => channels, "failures" => []} = body(conn)
    assert Enum.map(channels, & &1["channel"]) == ~w(push email extension)

    assert hd(channels) == %{
             "channel" => "push",
             "sent" => 0,
             "waiting" => 0,
             "skipped" => 0,
             "failed" => 0
           }
  end
end
