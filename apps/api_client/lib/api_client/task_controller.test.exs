defmodule ApiClient.TaskControllerTest do
  @moduledoc """
  The customer's board routes (AQ-02 §7.3, §7.6), pinned to the customer:
  the portal shapes, §9's routing, the verbs given to them, and the
  thread without a staff-only word.
  """

  use ApiClient.ClientCase, async: true

  alias Core.Tasks.Comments

  @portal_card ~w(id title state due_at due_on overdue profile source customer_access people on_it progress
                  comment_count file_count done_at closed yours_to_do made_by_you updated_at)
  @portal_sheet @portal_card ++ ~w(description checklist steps links files can)

  setup do: board_cast_fixture()

  test "POST /tasks: routed by §9, answered in the portal sheet's shape; GET /board", c do
    conn =
      as_customer(c.tanweer, :post, "/v1/tasks", %{
        title: "Apply to the Stripe role I sent",
        profile_id: c.golang.id,
        team_id: c.frontend.id
      })

    assert conn.status == 201
    sheet = body(conn)
    assert Enum.sort(Map.keys(sheet)) == Enum.sort(@portal_sheet)

    assert %{
             "made_by_you" => true,
             "yours_to_do" => false,
             "source" => "customer",
             "customer_access" => "shared",
             "profile" => %{"title" => "Golang backend"},
             "can" => %{
               "edit" => true,
               "withdraw" => true,
               "done" => false,
               "reopen" => false,
               "tick" => false,
               "comment" => true,
               "add_file" => true
             }
           } = sheet

    refute Map.has_key?(sheet, "team") or Map.has_key?(sheet, "priority") or
             Map.has_key?(sheet, "is_private")

    board = body(as_customer(c.tanweer, :get, "/v1/board"))

    assert %{
             "waiting_on_you" => [],
             "with_team" => [card],
             "done" => [],
             "older_done" => 0,
             "empty" => false
           } = board

    assert Enum.sort(Map.keys(card)) == Enum.sort(@portal_card)
    assert body(as_customer(c.naveed, :get, "/v1/board"))["empty"] == true
    assert call(c.fiza, :get, "/v1/board").status == 404
  end

  test "given to them: tick, mark done, reopen; their own: edit while To do, withdraw", c do
    given =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned,
        primary: c.fiza,
        checklist: ["Upload"]
      )

    step = step_fixture(given, is_for_customer: true, title: "Record a 2-minute intro")
    [item] = Data.Repo.preload(given, :checklist_items).checklist_items
    path = "/v1/tasks/#{given.id}"

    sheet = body(as_customer(c.tanweer, :get, path))
    assert sheet["yours_to_do"] and sheet["on_it"] == "Fiza"
    assert [%{"yours" => true, "on_it" => nil}] = sheet["steps"]
    refute Map.has_key?(hd(sheet["checklist"]), "checked_by")

    assert [%{"checked_at" => at}] =
             body(as_customer(c.tanweer, :post, "#{path}/checklist/#{item.id}/toggle"))[
               "checklist"
             ]

    assert is_binary(at)

    assert [%{"done_at" => done}] =
             body(as_customer(c.tanweer, :post, "#{path}/steps/#{step.id}/toggle"))["steps"]

    assert is_binary(done)

    assert as_customer(c.tanweer, :post, path <> "/done", %{from: "in_progress"}).status == 409

    assert body(as_customer(c.tanweer, :post, path <> "/done", %{from: "todo"}))["state"] ==
             "done"

    assert body(as_customer(c.tanweer, :post, path <> "/reopen", %{from: "done"}))["state"] ==
             "todo"

    assert as_customer(c.tanweer, :patch, path, %{title: "Mine now"}).status == 403
    assert as_customer(c.tanweer, :post, path <> "/withdraw", %{from: "todo"}).status == 403

    own = body(as_customer(c.tanweer, :post, "/v1/tasks", %{title: "Stop applying to agencies"}))

    assert body(
             as_customer(c.tanweer, :patch, "/v1/tasks/#{own["id"]}", %{title: "Stop agencies"})
           )["title"] == "Stop agencies"

    withdrawn =
      body(as_customer(c.tanweer, :post, "/v1/tasks/#{own["id"]}/withdraw", %{from: "todo"}))

    assert %{"state" => "closed", "closed" => %{"reason" => "withdrawn"}} = withdrawn

    assert as_customer(c.naveed, :get, path).status == 404
  end

  test "the thread: the customer never reads, writes or hears of a staff-only word", c do
    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        primary: c.fiza
      )

    staff =
      Comments.create(
        scope_for(c.fiza),
        task.id,
        %{"body" => "Check the salary band first"},
        DateTime.utc_now()
      )

    {:ok, [hidden]} = staff
    path = "/v1/tasks/#{task.id}/comments"

    assert body(as_customer(c.tanweer, :get, path)) == []
    [mine] = body(as_customer(c.tanweer, :post, path, %{body: "Thanks!", is_staff_only: true}))

    assert %{
             "is_staff_only" => false,
             "mine" => true,
             "author" => %{"is_customer" => true, "name" => "Tanweer"}
           } = mine

    assert as_customer(c.tanweer, :post, "#{path}/#{hidden.id}/replies", %{body: "?"}).status ==
             404

    assert as_customer(c.tanweer, :patch, "/v1/task-comments/#{hidden.id}", %{body: "?"}).status ==
             404

    assert hd(
             body(
               as_customer(c.tanweer, :patch, "/v1/task-comments/#{mine["id"]}", %{
                 body: "Thank you!"
               })
             )
           )["body"] == "Thank you!"

    assert [%{"deleted" => true}] =
             body(as_customer(c.tanweer, :delete, "/v1/task-comments/#{mine["id"]}"))

    tanweer_user = Data.Accounts.get_user(c.tanweer.user_id)
    assert Data.Notifications.for_task(tanweer_user.id, task.id) == []

    history = body(as_customer(c.tanweer, :get, "/v1/tasks/#{task.id}/history"))
    assert is_list(history)
  end

  test "a file added to a task they see", c do
    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared
      )

    scope = customer_scope_for(c.tanweer)

    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{"media_kind" => "attachment", "content_type" => "text/plain", "byte_count" => 2},
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, "hi")
    {:ok, _media} = Core.Media.confirm(scope, media.id, %{}, DateTime.utc_now())

    sheet =
      body(as_customer(c.tanweer, :post, "/v1/tasks/#{task.id}/files", %{media_id: media.id}))

    assert [%{"id" => id, "byte_count" => 2}] = sheet["files"]
    assert id == media.id
    refute Map.has_key?(hd(sheet["files"]), "added_by")
  end
end
