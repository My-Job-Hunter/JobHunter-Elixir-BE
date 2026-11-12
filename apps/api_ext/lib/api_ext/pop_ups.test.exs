defmodule ApiExt.PopUpsTest do
  @moduledoc """
  `GET /ext/v1/notifications/pop-ups` (AQ-08 §7.5, §11.4, §13 step 9): a
  reply raises one pop-up; the first poll claims it, a second poll — or a
  second device — gets nothing; the url opens the console with `n`. A
  console token is refused here (P5's `TokenApp`), as every `/ext` route
  refuses it.
  """

  use ApiExt.ExtCase, async: true

  alias Core.Auth.Guardian
  alias Data.Notifications.Deliveries

  setup do
    c = board_cast_fixture()
    {device, tokens} = connected(c.fiza)
    Map.merge(c, %{device: device, token: tokens.access_token})
  end

  defp reply(c, n) do
    {:ok, row} =
      Core.Notifications.ensure(Data.Scope.system(c.org), %{
        user_id: c.fiza.id,
        notification_kind_key: "conversations.reply_received",
        title: "Mei Chen replied on “Backend Developer · Bamboo Invest”",
        body: "Can we talk Thursday?",
        link_path: "/leads/#{n}",
        dedupe_key: "message:#{n}"
      })

    row
  end

  test "claimed by the first poll; the second, and a second device, get nothing", c do
    row = reply(c, 7)

    conn = call(c.token, :get, "/v1/notifications/pop-ups")
    assert conn.status == 200

    assert %{
             "items" => [
               %{
                 "id" => id,
                 "kind" => "conversations.reply_received",
                 "title" => "Mei Chen replied on “Backend Developer · Bamboo Invest”",
                 "body" => "Can we talk Thursday?",
                 "url" => url,
                 "at" => _
               }
             ]
           } = body(conn)

    assert id == row.id
    assert url == "http://localhost:5800/leads/7?n=#{row.id}"

    assert body(call(c.token, :get, "/v1/notifications/pop-ups")) == %{"items" => []}

    {_second, tokens} = connected(c.fiza)
    assert body(call(tokens.access_token, :get, "/v1/notifications/pop-ups")) == %{"items" => []}
  end

  test "a console token is refused: 401, and nothing is claimed", c do
    row = reply(c, 8)
    {:ok, console} = Guardian.tokens_for(c.fiza)

    conn = call(console.access_token, :get, "/v1/notifications/pop-ups")
    assert conn.status == 401
    assert code(conn) == "unauthenticated"
    assert call(nil, :get, "/v1/notifications/pop-ups").status == 401

    assert [%{state: :pending}] = Deliveries.for_notification(row.id)
  end

  test "the extension mounts no settings or push route", c do
    for {method, path} <- [
          get: "/v1/notifications/settings",
          put: "/v1/notifications/settings/groups/tasks",
          get: "/v1/me/push",
          post: "/v1/me/push/test"
        ] do
      assert call(c.token, method, path).status == 404, "#{method} #{path}"
    end
  end
end
