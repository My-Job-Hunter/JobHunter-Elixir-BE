defmodule ApiShared.NotificationControllerTest do
  @moduledoc "The bell's routes (AQ-02 §7.1), as every app serves them: each person their own."

  use ApiShared.SharedCase, async: true

  setup do
    org = organisation_fixture()
    user = admin_fixture(org)
    other = member_fixture(team_fixture(org), :member)
    %{org: org, user: user, other: other}
  end

  defp get(path, user), do: :get |> build(path) |> authed(user) |> request()
  defp post(path, user), do: :post |> build(path) |> authed(user) |> request()

  test "page, count, groups, read one, read all; another's is not found", %{
    org: org,
    user: user,
    other: other
  } do
    mine = for n <- 1..2, do: notification_fixture(org, user, dedupe_key: "k#{n}", task_id: nil)
    theirs = notification_fixture(org, other)

    conn = get("/v1/notifications?limit=1", user)
    assert conn.status == 200
    assert %{"items" => [item], "next_cursor" => cursor} = body(conn)

    assert %{"kind" => "tasks.assigned", "group" => "tasks", "read_at" => nil, "link_path" => nil} =
             item

    assert %{"items" => [_second], "next_cursor" => nil} =
             body(get("/v1/notifications?limit=1&cursor=#{cursor}", user))

    assert body(get("/v1/notifications/count", user)) == %{"unread" => 2}

    assert body(get("/v1/notifications/groups", user)) == [
             %{"key" => "tasks", "label" => "Tasks"}
           ]

    assert body(get("/v1/notifications?group=leads", user))["items"] == []

    assert post("/v1/notifications/#{theirs.id}/read", user).status == 404
    assert post("/v1/notifications/#{hd(mine).id}/read", user).status == 204
    assert body(get("/v1/notifications/count", user)) == %{"unread" => 1}
    assert post("/v1/notifications/read-all", user).status == 204
    assert body(get("/v1/notifications/count", user)) == %{"unread" => 0}
    assert body(get("/v1/notifications/count", other)) == %{"unread" => 1}
    assert get("/v1/notifications?cursor=junk", user).status == 422
    assert request(build(:get, "/v1/notifications")).status == 401
  end
end
