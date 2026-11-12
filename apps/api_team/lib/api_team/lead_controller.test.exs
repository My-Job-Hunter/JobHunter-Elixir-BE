defmodule ApiTeam.LeadControllerTest do
  @moduledoc """
  Leads over HTTP (AQ-04A §8.1, §8.3): `POST /leads` with a job or a new
  job's body, the sheet's keys, the board, the verbs with the frontend's
  bodies, the four new codes with their words, share links on a lead, and
  the pipelines.
  """

  use ApiTeam.TeamCase, async: true

  @sheet ~w(applied_at applied_by applied_confirmation applied_via archived_at bid can connects_spent
            cover_letter_md created_by customer cv expectation finished_at held_at hold_reason
            hold_until_on id is_pinned job last_activity_at outcome outcome_note owner pipeline
            priority profile progress recent resume_due stage state team follow_up labels next
            notes_count quiet tasks archive_reason recruiters tabs banner)
  @can ~w(apply apply_again archive assign cv edit finish hold move pin pipeline reopen resume share
          unarchive unpin)

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")
    Map.put(c, :job, job)
  end

  defp create(c, who, extra \\ %{}) do
    call(
      who,
      :post,
      "/v1/leads",
      Map.merge(%{job_id: c.job.id, profile_id: c.golang.id, as: "save"}, extra)
    )
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "POST /leads: 201 and the sheet's exact keys; GET and PATCH answer it", c do
    conn = create(c, c.fiza)
    assert conn.status == 201
    sheet = body(conn)
    assert keys(sheet) == Enum.sort(@sheet)
    assert keys(sheet["can"]) == Enum.sort(@can)
    assert sheet["state"] == "todo" and sheet["pipeline"]["key"] == "employment"
    assert [%{"kind" => "saved", "actor" => %{"kind" => "user"}}] = sheet["recent"]

    assert body(call(c.hira, :get, "/v1/leads/#{sheet["id"]}"))["id"] == sheet["id"]

    assert body(call(c.fiza, :patch, "/v1/leads/#{sheet["id"]}", %{priority: "high"}))["priority"] ==
             "high"
  end

  test "the codes: duplicate_application 409, lead_moved 409, outcome_required and override_reason_required 422",
       c do
    id = body(create(c, c.fiza))["id"]

    dup = create(c, c.qasim)
    assert dup.status == 409 and code(dup) == "duplicate_application"

    assert %{"team" => "this", "lead_id" => ^id, "by" => %{"name" => "Fiza"}} =
             body(dup)["error"]["details"]["existing"]

    todo = %{state: "todo", stage: nil}
    conn = call(c.fiza, :post, "/v1/leads/#{id}/apply", %{from: todo})
    assert conn.status == 200 and body(conn)["stage"]["key"] == "applied"

    stale = call(c.fiza, :post, "/v1/leads/#{id}/apply", %{from: todo})
    assert stale.status == 409 and code(stale) == "lead_moved"

    assert body(stale)["error"]["message"] ==
             "This lead moved while you were looking. It's now In progress · Applied."

    assert body(stale)["error"]["details"] == %{
             "state" => "in_progress",
             "stage" => %{"key" => "applied", "name" => "Applied"}
           }

    now = %{state: "in_progress", stage: "applied"}
    done = call(c.fiza, :post, "/v1/leads/#{id}/move", %{from: now, state: "done", stage: nil})
    assert done.status == 422 and code(done) == "outcome_required"
    assert body(done)["error"]["message"] == "Say how it ended."

    again = call(c.fiza, :post, "/v1/leads/#{id}/apply-again", %{from: now})
    assert again.status == 422 and code(again) == "override_reason_required"
    assert body(again)["error"]["message"] == "Say why you're applying again."
  end

  test "the verbs with the frontend's bodies: move into hold and done, resume, reopen, the flags, assign, pipeline",
       c do
    id = body(create(c, c.fiza, %{as: "apply"}))["id"]
    at = fn state, stage -> %{state: state, stage: stage} end

    held =
      call(c.fiza, :post, "/v1/leads/#{id}/move", %{
        from: at.("in_progress", "applied"),
        state: "on_hold",
        stage: "applied",
        hold_reason: "Visa",
        hold_until_on: "2026-11-20"
      })

    assert body(held)["state"] == "on_hold" and body(held)["hold_until_on"] == "2026-11-20"

    resumed = call(c.fiza, :post, "/v1/leads/#{id}/resume", %{from: at.("on_hold", "applied")})
    assert body(resumed)["state"] == "in_progress"

    finished =
      call(c.fiza, :post, "/v1/leads/#{id}/finish", %{
        from: at.("in_progress", "applied"),
        outcome: "rejected",
        outcome_note: "Too senior",
        close_job: false
      })

    assert body(finished)["outcome"] == "rejected" and
             body(finished)["outcome_note"] == "Too senior"

    reopened = call(c.fiza, :post, "/v1/leads/#{id}/reopen", %{from: at.("done", "applied")})
    assert body(reopened)["state"] == "in_progress"

    for verb <- ~w(pin unpin archive unarchive) do
      assert call(c.fiza, :post, "/v1/leads/#{id}/#{verb}").status == 200
    end

    assert body(call(c.fiza, :post, "/v1/leads/#{id}/assign", %{owner_user_id: c.qasim.id}))[
             "owner"
           ]["user_id"] == c.qasim.id

    switched =
      call(c.qasim, :post, "/v1/leads/#{id}/pipeline", %{
        from: at.("in_progress", "applied"),
        pipeline_key: "freelance"
      })

    assert body(switched)["pipeline"]["key"] == "freelance" and
             body(switched)["stage"]["key"] == "proposal_sent"
  end

  test "words on create: a team that doesn't serve the customer (403) and a paused customer (422)",
       c do
    imran = profile_fixture(c.imran, title: "AI/ML engineer")
    refused = create(c, c.fiza, %{profile_id: imran.id})

    assert refused.status == 403 and
             body(refused)["error"]["message"] == "Backend squad doesn't serve Imran."

    {:ok, _} = Data.Customers.change_status(c.naveed, :paused, ~D[2026-11-10])
    paused = create(c, c.fiza, %{profile_id: profile_fixture(c.naveed).id})
    assert paused.status == 422

    assert body(paused)["error"]["details"]["profile_id"] == [
             "Naveed is paused. Resume them before saving or applying for them."
           ]
  end

  test "GET /leads/board: the board's shape; a missing team_id is 422", c do
    _ = create(c, c.fiza)
    board = body(call(c.fiza, :get, "/v1/leads/board?team_id=#{c.backend.id}"))
    assert keys(board) == ~w(columns empty lane lanes older_done pipeline team view)
    assert Enum.map(board["columns"], & &1["key"]) == ~w(todo in_progress on_hold done)
    [card] = hd(board["columns"])["cards"]
    assert card["job"]["money"]["currency"] == nil and card["owner"]["name"] == "Fiza"

    expanded =
      body(
        call(
          c.fiza,
          :get,
          "/v1/leads/board?team_id=#{c.backend.id}&view=expanded&pipeline=freelance"
        )
      )

    assert expanded["pipeline"]["key"] == "freelance"
    assert call(c.fiza, :get, "/v1/leads/board").status == 422
  end

  test "share links on a lead, opened as subject lead", c do
    id = body(create(c, c.fiza))["id"]
    made = call(c.fiza, :post, "/v1/leads/#{id}/share-links", %{level: "details_history"})
    assert made.status == 201
    "/s/" <> token = body(made)["path"]
    shared = body(call(c.hira, :get, "/v1/shared/#{token}"))
    assert shared["subject"] == "lead" and is_list(shared["item"]["history"])
    refute Map.has_key?(shared["item"], "can")
    assert length(body(call(c.fiza, :get, "/v1/leads/#{id}/share-links"))) == 1
  end

  test "the pipelines: read by staff, written by a team lead; a member is refused in words", c do
    [employment, _freelance] = body(call(c.muaz, :get, "/v1/pipelines"))
    assert employment["version"] == 1 and employment["can_edit"] == false

    stages = Enum.map(employment["stages"], &Map.take(&1, ~w(key name kind)))
    refused = call(c.muaz, :put, "/v1/pipelines/employment", %{stages: stages})

    assert refused.status == 403 and
             body(refused)["error"]["message"] == "Only a team lead can change a pipeline."

    added = stages ++ [%{name: "Reference check", kind: "custom", anchor_kind: "negotiation"}]
    saved = body(call(c.hira, :put, "/v1/pipelines/employment", %{stages: added}))
    assert saved["version"] == 2 and List.last(saved["stages"])["key"] == "reference_check"
    assert body(call(c.muaz, :get, "/v1/pipelines/employment"))["version"] == 2
    assert call(c.muaz, :get, "/v1/pipelines/nope").status == 404
  end

  test "POST /jobs/check with profile_id carries the lead half; GET /jobs/:id the leads panel",
       c do
    _ = create(c, c.fiza, %{as: "apply"})

    check =
      body(
        call(c.fiza, :post, "/v1/jobs/check", %{
          team_id: c.backend.id,
          url: c.job.source_url,
          profile_id: c.golang.id
        })
      )

    assert check["lead"]["answer"] == "refused"
    assert check["lead"]["existing"]["by"]["name"] == "Fiza"

    sheet = body(call(c.hira, :get, "/v1/jobs/#{c.job.id}"))
    assert [%{"profile" => %{"title" => "Golang backend"}}] = sheet["leads"]
    assert sheet["hidden_leads"] == 0
  end
end
