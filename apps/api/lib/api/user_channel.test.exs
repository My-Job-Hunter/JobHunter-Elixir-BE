defmodule Api.UserChannelTest do
  @moduledoc "`user:<id>` (AQ-02 §7.4): that person only; a new notification, a new assignment, a read."

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  test "only that person joins", c do
    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(c.fiza), Api.UserChannel, "user:" <> c.fiza.id)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(c.fiza), Api.UserChannel, "user:" <> c.qasim.id)
  end

  test "hears notification_created and task_assigned when given work, notifications_read when read",
       c do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(c.fiza), Api.UserChannel, "user:" <> c.fiza.id)

    {:ok, sheet} =
      Core.Tasks.create(
        scope_for(c.hira),
        %{"title" => "Shortlist", "team_id" => c.backend.id, "primary_user_id" => c.fiza.id},
        @now
      )

    task_id = sheet.id
    [notification] = Data.Notifications.for_task(c.fiza.id, task_id)
    notification_id = notification.id
    assert_push "notification_created", %{id: ^notification_id}
    assert_push "task_assigned", %{task: ^task_id}

    assert :ok = Core.Notifications.read_all(scope_for(c.fiza), @now)
    assert_push "notifications_read", %{}

    assert {:reply, {:error, %{reason: "read_only"}}, _socket} =
             Api.UserChannel.handle_in("anything", %{}, socket)
  end
end
