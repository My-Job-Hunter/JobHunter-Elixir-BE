defmodule ApiTeam.TaskPartControllerTest do
  @moduledoc "A task's parts in the console (AQ-02 §7.2): each route answers the sheet."

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    # P2's privacy, as these routes were written to: teammates' tasks hidden.
    {:ok, _settings} = Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})

    Map.put(
      c,
      :task,
      task_fixture(scope_for(c.hira), team: c.backend, customer: c.tanweer, primary: c.fiza)
    )
  end

  test "checklist: add, rename, toggle, reorder, remove", c do
    path = "/v1/tasks/#{c.task.id}/checklist"
    [one] = body(call(c.fiza, :post, path, %{text: "Export"}))["checklist"]
    [_one, two] = body(call(c.fiza, :post, path, %{text: "Upload"}))["checklist"]

    assert %{"text" => "Export as PDF"} =
             hd(
               body(call(c.fiza, :patch, "#{path}/#{one["id"]}", %{text: "Export as PDF"}))[
                 "checklist"
               ]
             )

    assert %{"checked_at" => at, "checked_by" => %{"name" => "Fiza"}} =
             hd(body(call(c.fiza, :post, "#{path}/#{one["id"]}/toggle"))["checklist"])

    assert is_binary(at)

    assert [%{"id" => first}, _] =
             body(call(c.fiza, :put, "#{path}/order", %{ids: [two["id"], one["id"]]}))[
               "checklist"
             ]

    assert first == two["id"]
    assert call(c.fiza, :put, "#{path}/order", %{ids: [one["id"]]}).status == 422
    assert [_left] = body(call(c.fiza, :delete, "#{path}/#{one["id"]}"))["checklist"]
    assert call(c.muaz, :post, path, %{text: "x"}).status == 404
  end

  test "steps: add, edit, toggle, nudge, reorder, remove; for the customer only on a task about one",
       c do
    path = "/v1/tasks/#{c.task.id}/steps"

    [step] =
      body(call(c.hira, :post, path, %{title: "Shortlist", assignee_user_id: c.muaz.id}))["steps"]

    assert %{"assignee" => %{"name" => "Muaz"}, "is_for_customer" => false, "mine" => false} =
             step

    [_step, yours] =
      body(call(c.hira, :post, path, %{title: "Confirm Tuesday", is_for_customer: true}))["steps"]

    assert yours["is_for_customer"] and yours["assignee"] == nil

    assert %{"title" => "Shortlist ten"} =
             hd(
               body(call(c.hira, :patch, "#{path}/#{step["id"]}", %{title: "Shortlist ten"}))[
                 "steps"
               ]
             )

    assert %{"done_by" => %{"name" => "Muaz"}} =
             hd(body(call(c.muaz, :post, "#{path}/#{step["id"]}/toggle"))["steps"])

    assert call(c.hira, :post, "#{path}/#{yours["id"]}/nudge").status == 200
    assert call(c.hira, :post, "#{path}/#{step["id"]}/nudge").status == 422
    assert call(c.hira, :put, "#{path}/order", %{ids: [yours["id"], step["id"]]}).status == 200
    assert [_one] = body(call(c.hira, :delete, "#{path}/#{step["id"]}"))["steps"]

    personal = task_fixture(scope_for(c.hira))

    conn =
      call(c.hira, :post, "/v1/tasks/#{personal.id}/steps", %{title: "x", is_for_customer: true})

    assert conn.status == 403
    assert body(conn)["error"]["message"] == "This task isn't about a customer."
  end

  test "links, relations, files", c do
    path = "/v1/tasks/#{c.task.id}"
    other = task_fixture(scope_for(c.hira), team: c.backend, title: "Shortlist")

    [link] =
      body(
        call(c.fiza, :post, path <> "/links", %{
          url: "https://jobs.example.com/1",
          label: "The role"
        })
      )["links"]

    assert %{"url" => "https://jobs.example.com/1", "label" => "The role", "position" => 0} = link
    assert call(c.fiza, :post, path <> "/links", %{url: "javascript:alert(1)"}).status == 422
    assert body(call(c.fiza, :delete, "#{path}/links/#{link["id"]}"))["links"] == []

    # Hira's other task is not one Fiza may see: not found for her.
    assert call(c.fiza, :post, path <> "/relations", %{task_id: other.id, kind: "blocks"}).status ==
             404

    [relation] =
      body(call(c.hira, :post, path <> "/relations", %{task_id: other.id, kind: "blocks"}))[
        "relations"
      ]

    assert %{
             "kind" => "blocks",
             "direction" => "outgoing",
             "task" => %{"title" => "Shortlist", "state" => "todo"}
           } = relation

    assert call(c.hira, :post, path <> "/relations", %{task_id: other.id, kind: "parent_of"}).status ==
             422

    assert body(call(c.hira, :delete, "#{path}/relations/#{relation["id"]}"))["relations"] == []

    scope = scope_for(c.fiza)

    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{"media_kind" => "attachment", "content_type" => "text/plain", "byte_count" => 2},
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, "hi")
    {:ok, _media} = Core.Media.confirm(scope, media.id, %{}, DateTime.utc_now())

    [file] = body(call(c.fiza, :post, path <> "/files", %{media_id: media.id}))["files"]

    assert %{
             "id" => id,
             "content_type" => "text/plain",
             "byte_count" => 2,
             "added_by" => %{"name" => "Fiza"},
             "url" => "/media/" <> _
           } = file

    assert id == media.id
    assert body(call(c.fiza, :delete, "#{path}/files/#{media.id}"))["files"] == []
  end
end
