defmodule Core.Tasks.CommentsTest do
  @moduledoc """
  The thread (AQ-02 §7.2, §8): staff-only comments never reach the customer
  — not in the thread, not in a notification, not in the history; a
  mention is told once, as *mentioned*; the muted hear only mentions.
  """

  use Core.CoreCase, async: true

  alias Core.Tasks
  alias Core.Tasks.{Comments, People}
  alias Data.Notifications

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup c do
    c = Map.merge(c, board_cast_fixture())

    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        primary: c.fiza,
        secondary: [c.qasim]
      )

    Map.merge(c, %{task: task, tanweer_user: Data.Accounts.get_user(c.tanweer.user_id)})
  end

  defp told(user, task),
    do:
      user.id
      |> Notifications.for_task(task.id)
      |> Enum.map(&{&1.notification_kind_key, &1.title})

  test "a staff-only comment and its replies never reach the customer", c do
    fiza = scope_for(c.fiza)

    assert {:ok, [comment]} =
             Comments.create(
               fiza,
               c.task.id,
               %{"body" => "Check the salary band first", "is_staff_only" => true},
               @now
             )

    assert comment.is_staff_only

    assert {:ok, thread} =
             Comments.create(
               fiza,
               c.task.id,
               %{"body" => "On it: applying today", "is_staff_only" => false},
               @now
             )

    assert length(thread) == 2

    # A reply to a staff-only comment is staff-only, whatever it asked.
    assert {:ok, _thread} =
             Comments.reply(
               scope_for(c.hira),
               c.task.id,
               comment.id,
               %{"body" => "Noted", "is_staff_only" => false},
               @now
             )

    tanweer = customer_scope_for(c.tanweer)
    assert {:ok, [visible]} = Comments.thread(tanweer, c.task.id)
    assert visible.body == "On it: applying today"
    assert visible.replies == []

    assert {:error, :not_found} =
             Comments.reply(tanweer, c.task.id, comment.id, %{"body" => "?"}, @now)

    assert told(c.tanweer_user, c.task) == [
             {"tasks.commented", "Fiza commented on “#{c.task.title}”"}
           ]

    assert {:ok, history} = Tasks.history(tanweer, c.task.id)

    refute Enum.any?(history, fn g ->
             Enum.any?(g.lines, &(&1.field not in [:created, :customer_access]))
           end)
  end

  test "Team only unless said otherwise (QP2-5); the customer never writes one", c do
    assert {:ok, [%{is_staff_only: true}]} =
             Comments.create(scope_for(c.fiza), c.task.id, %{"body" => "x"}, @now)

    assert {:ok, [_staff, %{is_staff_only: false, author: %{is_customer: true}}]} =
             Comments.create(
               customer_scope_for(c.tanweer),
               c.task.id,
               %{"body" => "Thanks!", "is_staff_only" => true},
               @now
             )
             |> then(fn {:ok, _thread} -> Comments.thread(scope_for(c.fiza), c.task.id) end)

    assert {"tasks.commented", "Tanweer commented on “#{c.task.title}”"} in told(c.fiza, c.task)
  end

  test "a mention is told once, as mentioned; the actor is never told; the muted hear only mentions",
       c do
    {:ok, _sheet} = People.mute(scope_for(c.qasim), c.task.id, true, @now)

    {:ok, [comment]} =
      Comments.create(
        scope_for(c.fiza),
        c.task.id,
        %{"body" => "Team only", "is_staff_only" => true},
        @now
      )

    assert {:ok, _thread} =
             Comments.reply(
               scope_for(c.hira),
               c.task.id,
               comment.id,
               %{
                 "body" => "@Qasim please look",
                 "mention_user_ids" => [c.qasim.id, c.tanweer_user.id, c.hira.id, "nope"]
               },
               @now
             )

    assert told(c.qasim, c.task) == [
             {"tasks.mentioned", "Hira mentioned you on “#{c.task.title}”"}
           ]

    assert told(c.hira, c.task) == [{"tasks.commented", "Fiza commented on “#{c.task.title}”"}]
    assert told(c.tanweer_user, c.task) == []
    assert Enum.count(told(c.fiza, c.task)) == 1
  end

  test "only the author edits or deletes; a delete keeps the place", c do
    {:ok, [comment]} =
      Comments.create(
        scope_for(c.fiza),
        c.task.id,
        %{"body" => "First", "is_staff_only" => false},
        @now
      )

    assert {:error, {:forbidden, "You can only change your own comment."}} =
             Comments.edit(scope_for(c.hira), :comment, comment.id, %{"body" => "x"}, @now)

    assert {:ok, [%{body: "Better", edited_at: @now}]} =
             Comments.edit(scope_for(c.fiza), :comment, comment.id, %{"body" => "Better"}, @now)

    assert {:ok, [%{body: "", deleted: true}]} =
             Comments.delete(scope_for(c.fiza), :comment, comment.id, @now)

    assert {:error, :not_found} =
             Comments.edit(scope_for(c.fiza), :comment, comment.id, %{"body" => "x"}, @now)
  end

  test "a member at view comments on a peer's task; at hidden it is not found", c do
    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})

    assert {:error, :not_found} =
             Comments.create(scope_for(c.muaz), c.task.id, %{"body" => "x"}, @now)

    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :view})

    assert {:ok, [_one]} =
             Comments.create(scope_for(c.muaz), c.task.id, %{"body" => "Seen it"}, @now)
  end
end
