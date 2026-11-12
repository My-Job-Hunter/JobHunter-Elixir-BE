defmodule ApiTeam.LeadPageRoutesTest do
  @moduledoc """
  AQ-04B §8.1 over HTTP, with the exact request bodies the console sends:
  History, notes, *Log follow-up*, a lead's labels, labels, the Tracker and
  its CSV, bulk, saved views, the retention preview and Customer ›
  Activity — the shapes of §8.4, and the refusals in the house error shape.
  """

  use ApiTeam.TeamCase, async: true

  @tracker_row ~w(applied_at cv customer company engagement id labels last_activity_at missing money
                  next outcome owner profile quiet source stage state title workplace)

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")

    lead =
      body(
        call(c.fiza, :post, "/v1/leads", %{
          job_id: job.id,
          profile_id: c.golang.id,
          as: "apply"
        })
      )

    Map.merge(c, %{job: job, lead: lead})
  end

  defp from(lead), do: %{state: lead["state"], stage: lead["stage"]["key"]}
  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "notes: add, list, edit, delete; the note's shape; Qasim refused in words", c do
    id = c.lead["id"]

    note =
      body(call(c.fiza, :post, "/v1/leads/#{id}/notes", %{body_md: "Spoke to the recruiter."}))

    assert keys(note) == ~w(author body_md can id inserted_at updated_at)
    assert note["can"] == %{"edit" => true, "delete" => true}

    assert [%{"id" => note_id}] = body(call(c.hira, :get, "/v1/leads/#{id}/notes"))

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})
    refused = call(c.qasim, :patch, "/v1/lead-notes/#{note_id}", %{body_md: "Mine"})
    assert refused.status == 403 and code(refused) == "forbidden"

    assert body(call(c.hira, :patch, "/v1/lead-notes/#{note_id}", %{body_md: "Hira's"}))[
             "body_md"
           ] == "Hira's"

    assert call(c.fiza, :delete, "/v1/lead-notes/#{note_id}").status == 204
  end

  test "History: newest first, filtered by kind; the event carries task_id and note_id", c do
    id = c.lead["id"]
    _ = call(c.fiza, :post, "/v1/leads/#{id}/notes", %{body_md: "N"})

    page = body(call(c.fiza, :get, "/v1/leads/#{id}/history"))
    assert keys(page) == ~w(items next_cursor)

    assert [%{"kind" => "note_added", "note" => "N", "note_id" => _}, %{"kind" => "applied"}] =
             page["items"]

    moves = body(call(c.fiza, :get, "/v1/leads/#{id}/history?kind=applied,stage_moved"))
    assert Enum.map(moves["items"], & &1["kind"]) == ["applied"]
  end

  test "the sheet's P4b keys; Log follow-up with {from, note}; labels with {label_ids}", c do
    id = c.lead["id"]
    sheet = body(call(c.fiza, :get, "/v1/leads/#{id}"))
    assert sheet["follow_up"] == %{"state" => "none", "count" => 0, "of" => 2}
    assert keys(sheet["quiet"]) == ~w(archives_on days_left purges_on since warn)
    assert sheet["tasks"] == [] and sheet["notes_count"] == 0 and sheet["labels"] == []

    logged =
      body(
        call(c.fiza, :post, "/v1/leads/#{id}/follow-up", %{from: from(c.lead), note: "Nudged"})
      )

    assert logged["follow_up"]["count"] == 1

    label = body(call(c.hira, :post, "/v1/labels", %{team_id: c.backend.id, name: "Referral"}))
    assert keys(label) == ~w(id lead_count name)

    muaz = call(c.muaz, :post, "/v1/labels", %{team_id: c.backend.id, name: "Mine"})
    assert muaz.status == 403
    assert body(muaz)["error"]["message"] == "Only a team lead can change the team's labels."

    labelled = body(call(c.fiza, :put, "/v1/leads/#{id}/labels", %{label_ids: [label["id"]]}))
    assert labelled["labels"] == [%{"id" => label["id"], "name" => "Referral"}]

    assert [%{"lead_count" => 1}] = body(call(c.fiza, :get, "/v1/labels?team_id=#{c.backend.id}"))
    assert call(c.hira, :patch, "/v1/labels/#{label["id"]}", %{name: "Referrals"}).status == 200
    assert call(c.hira, :delete, "/v1/labels/#{label["id"]}").status == 204
  end

  test "the Tracker: the page and the row's exact keys; the CSV with a BOM", c do
    page = body(call(c.fiza, :get, "/v1/tracker?team_id=#{c.backend.id}&sort=title&group=state"))
    assert keys(page) == ~w(groups items next_cursor total)
    assert page["total"] == 1
    [row] = page["items"]
    assert keys(row) == Enum.sort(@tracker_row)
    assert keys(row["quiet"]) == ~w(archives_on warn)
    assert page["groups"] == [%{"key" => "in_progress", "name" => "In progress", "count" => 1}]

    csv = call(c.fiza, :get, "/v1/tracker.csv?team_id=#{c.backend.id}")
    assert csv.status == 200
    assert ["text/csv; charset=utf-8"] = Plug.Conn.get_resp_header(csv, "content-type")
    assert [disposition] = Plug.Conn.get_resp_header(csv, "content-disposition")
    assert disposition =~ "attachment; filename=\"tracker-backend-squad-"
    assert String.starts_with?(csv.resp_body, "﻿Applied,")

    assert code(call(c.fiza, :get, "/v1/tracker?team_id=#{c.backend.id}&sort=nope")) ==
             "validation_failed"
  end

  test "bulk: {done, refused: [{id, code, message}]}", c do
    other = lead_fixture(scope_for(c.qasim), team: c.backend)
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    result =
      body(
        call(c.fiza, :post, "/v1/leads/bulk", %{
          action: "archive",
          lead_ids: [c.lead["id"], other.id]
        })
      )

    assert result["done"] == [c.lead["id"]]

    assert [%{"id" => id, "code" => "forbidden", "message" => message}] = result["refused"]

    assert id == other.id and
             message == "Only the lead's owner, or a team lead, can archive or pin it."

    moved =
      body(
        call(c.fiza, :post, "/v1/leads/bulk", %{
          action: "unarchive",
          lead_ids: [c.lead["id"]],
          seen: [%{id: c.lead["id"], state: "todo", stage: nil}]
        })
      )

    assert [%{"code" => "lead_moved"}] = moved["refused"]

    assert code(call(c.fiza, :post, "/v1/leads/bulk", %{action: "archive", lead_ids: []})) ==
             "validation_failed"
  end

  test "saved views: the shape, the owner's alone", c do
    view =
      body(
        call(c.fiza, :post, "/v1/saved-views", %{
          screen: "tracker",
          name: "Golang · in progress",
          query: "team=#{c.backend.id}&state=in_progress",
          columns: ["title", "next"]
        })
      )

    assert keys(view) == ~w(columns id name position query screen)
    assert view["query"] == "state=in_progress" and view["columns"] == ["title", "next"]

    assert [_] = body(call(c.fiza, :get, "/v1/saved-views?screen=tracker"))
    assert call(c.hira, :patch, "/v1/saved-views/#{view["id"]}", %{name: "X"}).status == 404
    assert call(c.fiza, :patch, "/v1/saved-views/#{view["id"]}", %{name: "Y"}).status == 200
    assert call(c.fiza, :delete, "/v1/saved-views/#{view["id"]}").status == 204
  end

  test "the retention preview: the shape for a team lead; staff not found", c do
    preview = body(call(c.hira, :get, "/v1/retention/preview?team_id=#{c.backend.id}"))
    assert keys(preview) == ~w(archives jobs purges)
    assert call(c.fiza, :get, "/v1/retention/preview").status == 404
  end

  test "Customer › Activity: the system admin and a team lead; staff not found", c do
    page = body(call(c.dawud, :get, "/v1/customers/#{c.tanweer.id}/activity"))
    assert keys(page) == ~w(items next_cursor)
    assert call(c.bilal, :get, "/v1/customers/#{c.tanweer.id}/activity").status == 200
    assert call(c.fiza, :get, "/v1/customers/#{c.tanweer.id}/activity").status == 404
  end

  test "POST /tasks with lead_id: on the lead, in its team", c do
    task =
      body(
        call(c.fiza, :post, "/v1/tasks", %{
          title: "Send the portfolio link",
          team_id: c.backend.id,
          lead_id: c.lead["id"],
          customer_access: "shared"
        })
      )

    sheet = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}"))
    assert [%{"id" => id}] = sheet["tasks"]
    assert id == task["id"]
  end

  test "the board with lanes and older", c do
    board =
      body(call(c.fiza, :get, "/v1/leads/board?team_id=#{c.backend.id}&lane=owner&older=true"))

    assert board["lane"] == "owner"

    assert [%{"name" => "Fiza", "count" => 1, "key" => _, "columns" => [_, _, _, _]}] =
             board["lanes"]

    [card] = Enum.find(board["columns"], &(&1["key"] == "in_progress"))["cards"]
    assert Map.has_key?(card, "next") and Map.has_key?(card, "quiet") and card["labels"] == []
  end
end
