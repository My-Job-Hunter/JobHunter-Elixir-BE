defmodule ApiTeam.TaskCommentControllerTest do
  @moduledoc "A task's thread in the console (AQ-02 §7.2, §7.6): comments, replies, one's own edited or deleted."

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    # P2's privacy, as these routes were written to: teammates' tasks hidden.
    {:ok, _settings} = Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})

    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        primary: c.fiza
      )

    Map.put(c, :task, task)
  end

  test "comment, reply with a mention, edit and delete one's own; the thread's shape", c do
    path = "/v1/tasks/#{c.task.id}/comments"

    [comment] =
      body(call(c.fiza, :post, path, %{body: "Check the salary band first", is_staff_only: true}))

    assert %{
             "author" => %{"name" => "Fiza"},
             "is_staff_only" => true,
             "deleted" => false,
             "mine" => true,
             "replies" => [],
             "edited_at" => nil
           } =
             comment

    [_comment, shown] =
      body(call(c.fiza, :post, path, %{body: "On it: applying today", is_staff_only: false}))

    refute shown["is_staff_only"]

    [with_reply, _shown] =
      body(
        call(c.hira, :post, "#{path}/#{comment["id"]}/replies", %{
          body: "@Bilal look",
          mention_user_ids: [c.bilal.id, c.qasim.id]
        })
      )

    assert [%{"body" => "@Bilal look", "is_staff_only" => true} = reply] = with_reply["replies"]
    refute Map.has_key?(reply, "replies")

    assert [%{notification_kind_key: "tasks.mentioned"}] =
             Data.Notifications.for_task(c.bilal.id, c.task.id)

    # Qasim may not read the task: his mention is ignored.
    assert Data.Notifications.for_task(c.qasim.id, c.task.id) == []

    assert call(c.hira, :patch, "/v1/task-comments/#{comment["id"]}", %{body: "x"}).status == 403

    assert hd(body(call(c.fiza, :patch, "/v1/task-comments/#{comment["id"]}", %{body: "Edited"})))[
             "body"
           ] == "Edited"

    assert hd(
             hd(body(call(c.hira, :patch, "/v1/task-replies/#{reply["id"]}", %{body: "Better"})))[
               "replies"
             ]
           )["body"] == "Better"

    assert hd(hd(body(call(c.hira, :delete, "/v1/task-replies/#{reply["id"]}")))["replies"])[
             "deleted"
           ]

    assert %{"body" => "", "deleted" => true} =
             hd(body(call(c.fiza, :delete, "/v1/task-comments/#{comment["id"]}")))

    assert length(body(call(c.bilal, :get, path))) == 2
    assert call(c.muaz, :get, path).status == 404
  end
end
