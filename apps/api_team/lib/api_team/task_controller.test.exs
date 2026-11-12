defmodule ApiTeam.TaskControllerTest do
  @moduledoc "The console's board routes (AQ-02 §7.2): the page, a task's life, its verbs and the 409, in §7.6's shapes."

  use ApiTeam.TeamCase, async: true

  @card ~w(kind id title state stage priority due_at due_on overdue team customer profile customer_access source
           people needs_owner progress comment_count file_count hold closed done_at mine can_move updated_at)
  @sheet @card ++
           ~w(description reminder_minutes author inserted_at held_from_state checklist steps links relations files
              watchers me_on can customer_sees)

  setup do: board_cast_fixture()

  test "POST /tasks, GET, PATCH: the sheet in §7.6's shape; 404 for someone who may not see it",
       c do
    conn =
      call(c.hira, :post, "/v1/tasks", %{
        title: "Upload the updated CV",
        team_id: c.backend.id,
        customer_id: c.tanweer.id,
        customer_access: "assigned",
        due_on: "2026-11-12",
        primary_user_id: c.fiza.id,
        checklist: ["Export", "Upload"],
        steps: [%{title: "Record a 2-minute intro", assignee_user_id: c.muaz.id}]
      })

    assert conn.status == 201
    sheet = body(conn)
    assert Enum.sort(Map.keys(sheet)) == Enum.sort(@sheet)

    assert %{
             "kind" => "task",
             "state" => "todo",
             "customer_access" => "assigned",
             "customer" => %{"display_name" => "Tanweer"},
             "people" => [
               %{
                 "name" => "Fiza",
                 "level" => "primary",
                 "me" => false,
                 "user_id" => _,
                 "photo_url" => nil
               }
             ],
             "progress" => %{
               "checklist" => %{"done" => 0, "total" => 2},
               "steps" => %{"done" => 0, "total" => 1, "mine" => 0}
             },
             "can" => %{
               "edit" => true,
               "move" => true,
               "comment_staff_only" => true,
               "delete" => false,
               "change_visibility" => true,
               "share" => true
             },
             "team" => %{"name" => "Backend squad"},
             "me_on" => %{"watching" => false, "muted" => false},
             "author" => %{"name" => "Hira Khan"},
             "customer_sees" => true,
             "hold" => nil,
             "closed" => nil
           } = sheet

    id = sheet["id"]
    assert body(call(c.fiza, :get, "/v1/tasks/#{id}"))["id"] == id

    assert call(c.naveed |> then(&Data.Accounts.get_user(&1.user_id)), :get, "/v1/tasks/#{id}").status ==
             404

    assert call(c.muaz, :get, "/v1/tasks/#{Ecto.UUID.generate()}").status == 404

    # AQ-03B §5.1: the team is required, and `is_private` is gone.
    conn = call(c.hira, :post, "/v1/tasks", %{title: "Nowhere"})

    assert conn.status == 422 and
             body(conn)["error"]["details"] == %{"team_id" => ["is required"]}

    conn =
      call(c.hira, :post, "/v1/tasks", %{title: "x", team_id: c.backend.id, is_private: true})

    assert conn.status == 422 and Map.has_key?(body(conn)["error"]["details"], "is_private")
    assert call(c.muaz, :post, "/v1/tasks", %{title: "x", team_id: c.frontend.id}).status == 404

    conn =
      call(c.hira, :patch, "/v1/tasks/#{id}", %{title: "Upload the new CV", priority: "high"})

    assert %{"title" => "Upload the new CV", "priority" => "high"} = body(conn)

    conn = call(c.fiza, :patch, "/v1/tasks/#{id}", %{customer_access: "none"})
    assert conn.status == 403

    assert body(conn)["error"]["message"] ==
             "Only the task's author or a lead can change who sees it."

    assert call(c.hira, :post, "/v1/tasks", %{title: ""}).status == 422
  end

  test "the verbs carry `from`; a stale one answers 409 task_moved with where it is", c do
    task = task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza)
    path = "/v1/tasks/#{task.id}"

    assert body(call(c.fiza, :post, path <> "/start", %{from: "todo"}))["state"] == "in_progress"

    conn = call(c.fiza, :post, path <> "/done", %{from: "todo"})
    assert conn.status == 409

    assert body(conn)["error"] == %{
             "code" => "task_moved",
             "message" => "This task moved while you were looking. It's now In progress.",
             "details" => %{"state" => "in_progress", "stage" => nil}
           }

    assert call(c.fiza, :post, path <> "/hold", %{from: "in_progress"}).status == 422

    held =
      body(call(c.fiza, :post, path <> "/hold", %{from: "in_progress", reason: "The new CV"}))

    assert held["hold"]["reason"] == "The new CV" and held["held_from_state"] == "in_progress"

    assert body(call(c.fiza, :post, path <> "/resume", %{from: "on_hold"}))["state"] ==
             "in_progress"

    assert body(call(c.fiza, :post, path <> "/move", %{from: "in_progress", state: "done"}))[
             "state"
           ] == "done"

    assert body(call(c.fiza, :post, path <> "/reopen", %{from: "done"}))["state"] == "todo"

    closed =
      body(
        call(c.fiza, :post, path <> "/close", %{
          from: "todo",
          reason: "duplicate",
          note: "On Qasim's"
        })
      )

    assert closed["closed"]["reason"] == "duplicate" and closed["closed"]["note"] == "On Qasim's"

    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})
    conn = call(c.muaz, :post, path <> "/reopen", %{from: "closed"})
    assert conn.status == 404

    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :view})
    conn = call(c.muaz, :post, path <> "/reopen", %{from: "closed"})
    assert conn.status == 403

    assert body(conn)["error"]["message"] ==
             "You can see this, but only its people or a team lead can change it."
  end

  test "archive, unarchive, delete a draft; assignees, watch, mute; history; search", c do
    task = task_fixture(scope_for(c.hira), team: c.backend, title: "Shortlist ten Go roles")
    draft = task_fixture(scope_for(c.hira), team: c.backend, state: :draft)
    path = "/v1/tasks/#{task.id}"

    assert call(c.hira, :post, path <> "/archive").status == 200
    assert body(call(c.hira, :get, "/v1/tasks/search?q=go")) == []
    assert call(c.hira, :post, path <> "/unarchive").status == 200

    assert [%{"id" => id, "title" => "Shortlist ten Go roles", "state" => "todo"}] =
             body(call(c.hira, :get, "/v1/tasks/search?q=go"))

    assert id == task.id

    assert call(c.hira, :delete, path).status == 403
    assert call(c.hira, :delete, "/v1/tasks/#{draft.id}").status == 204

    conn =
      call(c.hira, :put, path <> "/assignees", %{
        primary_user_id: c.fiza.id,
        secondary_user_ids: [c.qasim.id]
      })

    assert [%{"name" => "Fiza"}, %{"name" => "Qasim"}] = body(conn)["people"]

    assert body(call(c.bilal, :post, path <> "/watch", %{on: true}))["me_on"] == %{
             "watching" => true,
             "muted" => false
           }

    assert body(call(c.bilal, :post, path <> "/mute", %{on: true}))["me_on"] == %{
             "watching" => true,
             "muted" => true
           }

    [latest | _older] = body(call(c.hira, :get, path <> "/history"))

    assert %{
             "change_group_id" => _,
             "actor" => %{"name" => "Bilal"},
             "changed_at" => _,
             "lines" => [%{"field" => "watchers"}]
           } = latest
  end

  test "GET /board in §7.6's shape: six columns as a list, counts by_state, the groups", c do
    task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza, state: :in_progress)

    page = body(call(c.fiza, :get, "/v1/board?team_id=#{c.backend.id}&mine=true"))

    assert Map.keys(page) |> Enum.sort() ==
             ~w(columns counts empty in_progress_groups people stages team teams)

    assert page["team"] == %{"id" => c.backend.id, "name" => "Backend squad"}

    assert Enum.map(page["columns"], & &1["state"]) ==
             ~w(draft todo in_progress on_hold done closed)

    assert page["counts"]["by_state"]["in_progress"] == 1

    assert %{"due_today" => 0, "overdue" => 0, "older_done" => 0, "older_closed" => 0} =
             page["counts"]

    assert [
             %{
               "key" => "none",
               "label" => "No stage",
               "stage" => nil,
               "person" => nil,
               "items" => [_one]
             }
           ] = page["in_progress_groups"]

    assert [%{"name" => "Fiza"}] = page["people"]

    assert [
             %{"name" => "Backend squad", "role" => "member"},
             %{"name" => "Frontend squad", "role" => "member"}
           ] = page["teams"]

    board = "/v1/board?team_id=#{c.backend.id}"
    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})
    assert body(call(c.muaz, :get, board))["empty"] == "team_hidden"
    assert call(c.muaz, :get, board <> "&customer_id=#{c.imran.id}").status == 404
    assert call(c.muaz, :get, board <> "&view=team").status == 422
    assert call(c.muaz, :get, "/v1/board").status == 422
    assert call(c.muaz, :get, "/v1/board?team_id=#{c.frontend.id}").status == 404
  end
end
