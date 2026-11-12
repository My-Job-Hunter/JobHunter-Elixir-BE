defmodule ApiClient.ApprovalControllerTest do
  @moduledoc """
  The portal's half of AQ-07 (§11.2, §11.4, §12.2): what waits on the
  customer, the count, the sheet with `team: null`, staff by first name
  (or "The team" when the team hides names) and `can` only `decide` and
  `comment`; *Approve* · *Request changes* · *Reject*; comments; the
  lead's approvals; a staff-only approval, a draft and another customer's
  are 404.
  """

  use ApiClient.ClientCase, async: true

  alias Core.Approvals

  @now ~U[2026-11-12 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    cv = document_fixture(c.golang, kind: :cv, label: "Golang v4")
    body = %{team_id: c.backend.id, lead_id: lead.id, body_md: "Send this one?"}

    {:ok, ask} =
      Approvals.draft(
        fiza,
        Map.merge(body, %{
          approval_kind: "cv_for_job",
          title: "CV for Bamboo",
          proposed: %{document_id: cv.id},
          submit: true
        }),
        @now
      )

    {:ok, staff_only} =
      Approvals.draft(
        fiza,
        Map.merge(body, %{
          approval_kind: "asset",
          title: "Staff only",
          slots: [%{slot: "team_lead"}],
          submit: true
        }),
        @now
      )

    {:ok, draft} =
      Approvals.draft(
        fiza,
        Map.merge(body, %{
          approval_kind: "rate",
          title: "Draft",
          proposed: %{
            expectation_minor: 1,
            expectation_currency: "USD",
            expectation_period: "year"
          }
        }),
        @now
      )

    Map.merge(c, %{lead: lead, cv: cv, ask: ask, staff_only: staff_only, draft: draft})
  end

  test "waiting on me, the count, the sheet cut for the customer", c do
    page = body(as_customer(c.tanweer, :get, "/v1/approvals"))
    assert [%{"id" => id, "requested_by" => %{"name" => "Fiza"}}] = page["items"]
    assert id == c.ask.id and page["next_cursor"] == nil
    assert body(as_customer(c.tanweer, :get, "/v1/approvals?tab=all"))["items"] |> length() == 1
    assert body(as_customer(c.tanweer, :get, "/v1/approvals/count")) == %{"waiting_on_me" => 1}

    sheet = body(as_customer(c.tanweer, :get, "/v1/approvals/#{id}"))
    assert sheet["team"] == nil

    assert sheet["can"] == %{
             "edit" => false,
             "submit" => false,
             "decide" => true,
             "revise" => false,
             "withdraw" => false,
             "comment" => true,
             "sent" => false
           }

    assert sheet["current"]["proposed"]["document"] == %{
             "id" => c.cv.id,
             "label" => "Golang v4",
             "version" => 1
           }

    # The team hides staff names: "The team".
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    hidden = body(as_customer(c.tanweer, :get, "/v1/approvals/#{id}"))
    assert hidden["requested_by"] == %{"user_id" => nil, "name" => "The team", "photo_url" => nil}

    for other <- [c.staff_only.id, c.draft.id] do
      assert as_customer(c.tanweer, :get, "/v1/approvals/#{other}").status == 404
    end

    assert as_customer(c.naveed, :get, "/v1/approvals/#{id}").status == 404
    assert body(as_customer(c.naveed, :get, "/v1/approvals"))["items"] == []

    assert body(as_customer(c.tanweer, :get, "/v1/approvals?tab=asked"))
           |> Map.get("error")
           |> Map.get("code") == "validation_failed"
  end

  test "deciding: a note for changes and rejections; approved sets the CV; the lead's tab", c do
    id = c.ask.id

    no_note =
      as_customer(c.tanweer, :post, "/v1/approvals/#{id}/decide", %{
        decision: "rejected",
        version: 1
      })

    assert no_note.status == 422 and
             body(no_note)["error"]["details"] == %{"note" => ["is required"]}

    comment =
      as_customer(c.tanweer, :post, "/v1/approvals/#{id}/comments", %{
        body_md: "Is this the latest?"
      })

    assert comment.status == 201
    assert body(comment)["author"]["name"] == "Tanweer"

    assert [%{"body_md" => "Is this the latest?"}] =
             body(as_customer(c.tanweer, :get, "/v1/approvals/#{id}/comments"))

    approved =
      as_customer(c.tanweer, :post, "/v1/approvals/#{id}/decide", %{
        decision: "approved",
        version: 1
      })

    assert approved.status == 200
    a = body(approved)
    assert a["state"] == "approved"

    assert a["effect"] == %{
             "state" => "applied",
             "words" => "Approved. Golang v4 is now the CV for this lead."
           }

    assert [
             %{
               "slot" => "customer",
               "open" => false,
               "person" => %{"name" => "Tanweer"},
               "decision" => decision
             }
           ] =
             a["slots"]

    assert %{"decision" => "approved", "note" => nil, "by" => %{"name" => "Tanweer"}} = decision
    assert Data.Leads.reload(c.lead).document_id == c.cv.id

    again =
      as_customer(c.tanweer, :post, "/v1/approvals/#{id}/decide", %{
        decision: "approved",
        version: 1
      })

    assert again.status == 409 and code(again) == "approval_not_pending"

    assert [%{"id" => ^id}] =
             body(as_customer(c.tanweer, :get, "/v1/leads/#{c.lead.id}/approvals"))

    assert [%{"id" => ^id}] =
             body(as_customer(c.tanweer, :get, "/v1/approvals?tab=all&lead_id=#{c.lead.id}"))[
               "items"
             ]

    assert body(
             as_customer(c.tanweer, :get, "/v1/approvals?tab=all&lead_id=#{Ecto.UUID.generate()}")
           )["items"] == []

    assert body(as_customer(c.tanweer, :get, "/v1/approvals/count")) == %{"waiting_on_me" => 0}

    gone = as_customer(c.tanweer, :delete, "/v1/approval-comments/#{body(comment)["id"]}")
    assert gone.status == 204
  end
end
