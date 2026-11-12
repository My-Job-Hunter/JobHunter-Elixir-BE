defmodule ApiTeam.ApprovalControllerTest do
  @moduledoc """
  AQ-07 §11.1 over HTTP with §11.4's status codes and shapes: 201 for
  `POST /approvals` and a comment, 200 for every verb, `PUT` and read, 204
  for deletes; 409 `approval_not_pending` with `{state, version}`; 403
  `not_reviewer`; each shape's exact keys — the approval row, the
  approval, the version, the slot, the comment, the policy row, the count
  and the page; the notification row's `approval_id`; the lead's `next`.
  """

  use ApiTeam.TeamCase, async: true

  alias Data.Fixtures.Approvals, as: ApprovalFixtures

  @row ~w(approval_kind customer due_at effect id lead overdue profile requested_by state title
          updated_at version waiting_on)
  @approval @row ++
              ~w(can comments_count current decided_at diff rule slots submitted_at team versions)
  @version ~w(at attachments body_html body_md by number proposed)
  @proposed ~w(bid connects document expectation headline skills summary title)
  @slot ~w(decision id open person slot)
  @can ~w(comment decide edit revise sent submit withdraw)

  setup do
    c = board_cast_fixture()
    bamboo = company_fixture(c.org, name: "Bamboo")

    job =
      job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer", company: bamboo)

    lead = lead_fixture(scope_for(c.fiza), job: job, profile: c.golang, as: :apply)
    # *All*: a named person adds a required yes (under *any* they are refused, AQ-07's run).
    ApprovalFixtures.policy_fixture(c.tanweer,
      approval_kind: :proposal,
      needs: :customer,
      rule: :all
    )

    Map.merge(c, %{lead: lead})
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "ask, change, revise, decide: the codes and the shapes", c do
    created =
      call(c.fiza, :post, "/v1/approvals", %{
        team_id: c.backend.id,
        approval_kind: "proposal",
        title: "Proposal for Bamboo",
        lead_id: c.lead.id,
        body_md: "I can start **Monday**.",
        proposed: %{bid_minor: 4500, bid_currency: "USD", bid_period: "hour", connects: 12},
        media_ids: [],
        slots: [%{slot: "user", user_id: c.hira.id}],
        due_at: "2026-12-01T12:00:00Z",
        submit: false
      })

    assert created.status == 201
    a = body(created)
    assert keys(a) == Enum.sort(@approval)
    assert keys(a["current"]) == Enum.sort(@version)
    assert keys(a["current"]["proposed"]) == Enum.sort(@proposed)
    assert keys(a["can"]) == Enum.sort(@can)
    assert a["state"] == "draft" and a["diff"] == [] and a["team"]["name"] == "Backend squad"
    assert a["lead"] == %{"id" => c.lead.id, "title" => "Backend Developer · Bamboo"}
    assert a["current"]["body_html"] =~ "<strong>Monday</strong>"
    assert a["effect"] == %{"state" => "none", "words" => nil}
    id = a["id"]

    patched = call(c.fiza, :patch, "/v1/approvals/#{id}", %{title: "Proposal · Bamboo"})
    assert patched.status == 200 and body(patched)["title"] == "Proposal · Bamboo"

    submitted = call(c.fiza, :post, "/v1/approvals/#{id}/submit")
    assert submitted.status == 200 and body(submitted)["state"] == "pending"
    assert [slot, _hira] = body(submitted)["slots"]
    assert keys(slot) == Enum.sort(@slot)

    asked =
      call(c.hira, :post, "/v1/approvals/#{id}/decide", %{
        decision: "changes_requested",
        note: "Make it 50.",
        version: 1
      })

    assert asked.status == 200 and body(asked)["state"] == "changes_requested"

    revised =
      call(c.fiza, :post, "/v1/approvals/#{id}/revise", %{
        body_md: "I can start **Monday**. I have shipped Go at scale.",
        proposed: %{bid_minor: 5000, bid_currency: "USD", bid_period: "hour", connects: 12}
      })

    assert revised.status == 200
    v2 = body(revised)
    assert v2["version"] == 2 and Enum.map(v2["versions"], & &1["number"]) == [1, 2]
    assert Enum.map(v2["diff"], & &1["field"]) == ["body_md", "bid"]

    # Qasim holds no slot: 403. A stale version: 409 with where it is.
    refused =
      call(c.qasim, :post, "/v1/approvals/#{id}/decide", %{decision: "approved", version: 2})

    assert refused.status == 403 and code(refused) == "not_reviewer"
    assert body(refused)["error"]["message"] == "This isn't yours to decide."

    stale = call(c.hira, :post, "/v1/approvals/#{id}/decide", %{decision: "approved", version: 1})
    assert stale.status == 409

    assert body(stale)["error"] == %{
             "code" => "approval_not_pending",
             "message" => "This approval changed while you were looking. It's now Waiting.",
             "details" => %{"state" => "pending", "version" => 2}
           }

    note = call(c.fiza, :post, "/v1/approvals/#{id}/comments", %{body_md: "Updated the bid."})
    assert note.status == 201
    assert keys(body(note)) == ~w(at author body_md can deleted id)

    thread = call(c.fiza, :get, "/v1/approvals/#{id}/comments")
    assert [%{"body_md" => "Updated the bid."}] = body(thread)

    gone = call(c.fiza, :delete, "/v1/approval-comments/#{body(note)["id"]}")
    assert gone.status == 204

    page = body(call(c.fiza, :get, "/v1/approvals?team_id=#{c.backend.id}&tab=asked"))
    assert keys(page) == ~w(items next_cursor)
    assert [row] = page["items"]
    assert keys(row) == Enum.sort(@row)

    assert [
             %{"slot" => "customer", "person" => nil},
             %{"slot" => "user", "person" => %{"name" => "Hira Khan"}}
           ] =
             row["waiting_on"]

    assert body(call(c.hira, :get, "/v1/approvals/count?team_id=#{c.backend.id}")) == %{
             "waiting_on_me" => 1
           }

    assert body(call(c.hira, :get, "/v1/approvals/count")) == %{"waiting_on_me" => 1}
    assert [%{"id" => ^id}] = body(call(c.fiza, :get, "/v1/leads/#{c.lead.id}/approvals"))

    sheet = body(call(c.fiza, :get, "/v1/leads/#{c.lead.id}"))
    assert sheet["tabs"]["approvals"] == 1
    assert %{"kind" => "approval", "approval_id" => ^id} = sheet["next"]

    history = body(call(c.fiza, :get, "/v1/leads/#{c.lead.id}/history"))

    assert Enum.any?(
             history["items"],
             &(&1["kind"] == "approval_requested" and &1["approval_id"] == id)
           )

    bell = body(call(c.fiza, :get, "/v1/notifications"))

    assert Enum.any?(
             bell["items"],
             &(&1["kind"] == "approvals.decided" and &1["approval_id"] == id)
           )

    assert Enum.all?(bell["items"], &Map.has_key?(&1, "approval_id"))

    withdrawn = call(c.fiza, :post, "/v1/approvals/#{id}/withdraw")
    assert withdrawn.status == 200 and body(withdrawn)["state"] == "withdrawn"

    assert call(c.fiza, :post, "/v1/approvals/#{id}/sent").status == 422
  end

  test "an ad hoc kind without slots is 422 on slots; a draft is 404 to a teammate", c do
    bad =
      call(c.fiza, :post, "/v1/approvals", %{
        team_id: c.backend.id,
        approval_kind: "other",
        title: "x",
        lead_id: c.lead.id,
        body_md: ""
      })

    assert bad.status == 422 and
             body(bad)["error"]["details"] == %{"slots" => ["says who decides"]}

    draft =
      body(
        call(c.fiza, :post, "/v1/approvals", %{
          team_id: c.backend.id,
          approval_kind: "other",
          title: "x",
          lead_id: c.lead.id,
          body_md: "",
          slots: [%{slot: "team_lead"}]
        })
      )

    assert call(c.qasim, :get, "/v1/approvals/#{draft["id"]}").status == 404
    assert call(c.bilal, :get, "/v1/approvals/#{draft["id"]}").status == 200
  end

  test "policies: the eight rows; PUT 200 by a team lead, 403 for staff; DELETE 204", c do
    rows = body(call(c.qasim, :get, "/v1/customers/#{c.tanweer.id}/approval-policies"))
    assert length(rows) == 8

    assert Enum.all?(
             rows,
             &(keys(&1) == ~w(approval_kind auto_approve_hours is_default needs rule))
           )

    put =
      call(c.bilal, :put, "/v1/customers/#{c.tanweer.id}/approval-policies/reply", %{
        needs: "both",
        rule: "all",
        auto_approve_hours: 24
      })

    assert put.status == 200

    assert body(put) == %{
             "approval_kind" => "reply",
             "needs" => "both",
             "rule" => "all",
             "auto_approve_hours" => 24,
             "is_default" => false
           }

    staff =
      call(c.qasim, :put, "/v1/customers/#{c.tanweer.id}/approval-policies/reply", %{
        needs: "both",
        rule: "all"
      })

    assert staff.status == 403 and
             body(staff)["error"]["message"] == "Only a team lead can change approval rules."

    assert call(c.bilal, :put, "/v1/customers/#{c.tanweer.id}/approval-policies/nope", %{
             needs: "both",
             rule: "all"
           }).status == 404

    assert call(c.bilal, :delete, "/v1/customers/#{c.tanweer.id}/approval-policies/reply").status ==
             204

    assert %{"is_default" => true, "needs" => "team_lead"} =
             hd(body(call(c.bilal, :get, "/v1/customers/#{c.tanweer.id}/approval-policies")))
  end
end
