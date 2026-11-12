defmodule Core.ApprovalsTest do
  @moduledoc """
  AQ-07 P7.0–P7.2 through the contexts: a three-version approval with its
  files and diffs; drafting by the customer's policy (and its refusals);
  deciding — *any* and *all*, `not_reviewer`, the stale 409, the note —
  and *Recorded as sent* for a reply; comments. Every kind's effect, the
  page and the policies are `Core.Approvals.EffectsTest`.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Approvals
  alias Core.Approvals.{Act, Comments}
  alias Data.Notifications.Notification

  @now ~U[2026-11-12 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    bamboo = company_fixture(c.org, name: "Bamboo")
    job = job_fixture(fiza, team: c.backend, title: "Backend Developer", company: bamboo)
    lead = lead_fixture(fiza, job: job, profile: c.golang, as: :apply)
    cv = document_fixture(c.golang, kind: :cv, label: "Golang v4")

    Map.merge(c, %{
      fiza_s: fiza,
      tanweer_s: customer_scope_for(c.tanweer),
      lead: lead,
      cv: cv
    })
  end

  defp attachment(scope, text, name) do
    {:ok, media} = Core.Media.store_attachment(scope, text, name, @now)
    media
  end

  defp ask(c, scope, attrs) do
    Approvals.draft(
      scope,
      Map.merge(%{team_id: c.backend.id, lead_id: c.lead.id, title: "Ask", body_md: ""}, attrs),
      @now
    )
  end

  defp notices(user, approval_id) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user.id and n.approval_id == ^approval_id,
        order_by: n.inserted_at
      )
    )
  end

  defp events(lead_id, kind) do
    lead_id |> Data.Leads.events() |> Enum.filter(&(&1.kind == kind))
  end

  test "a three-version proposal: changes requested, revised twice, each version's files and diff kept",
       c do
    rate_card = attachment(c.fiza_s, "Rate card: USD 45 an hour\n", "rate-card.txt")

    {:ok, a} =
      ask(c, c.fiza_s, %{
        approval_kind: "proposal",
        title: "Proposal for Bamboo",
        body_md: "I can start Monday.",
        proposed: %{bid_minor: 4500, bid_currency: "USD", bid_period: "hour", connects: 12},
        media_ids: [rate_card.id],
        submit: true
      })

    assert %{state: :pending, version: 1, diff: [], current: %{number: 1} = v1} = a
    assert [%{slot: :customer, open: true, person: nil, decision: nil}] = a.slots
    assert [%{slot: :customer, person: nil}] = a.waiting_on
    assert v1.proposed.bid.min_minor == 4500 and v1.proposed.connects == 12

    assert [%{media_id: id, filename: "rate-card.txt", content_type: "text/plain"}] =
             v1.attachments

    assert id == rate_card.id

    {:ok, a} =
      Act.decide(
        c.tanweer_s,
        a.id,
        %{decision: "changes_requested", note: "Make it 50.", version: 1},
        @now
      )

    assert a.state == :changes_requested
    assert [%{decision: %{decision: :changes_requested, note: "Make it 50."}}] = a.slots

    {:ok, a} =
      Act.revise(
        c.fiza_s,
        a.id,
        %{
          body_md: "I can start Monday. I have shipped Go at scale.",
          proposed: %{bid_minor: 5000, bid_currency: "USD", bid_period: "hour", connects: 12}
        },
        @now
      )

    assert %{state: :pending, version: 2, current: %{number: 2} = v2} = a
    assert Enum.map(a.versions, & &1.number) == [1, 2]
    assert [%{media_id: ^id}] = v2.attachments
    assert [%{slot: :customer, open: true, decision: nil}] = a.slots

    assert a.diff == [
             %{
               field: "body_md",
               parts: [
                 %{op: "same", text: "I can start Monday."},
                 %{op: "added", text: " I have shipped Go at scale."}
               ]
             },
             %{
               field: "bid",
               parts: [
                 %{op: "removed", text: "USD 45 / hour"},
                 %{op: "added", text: "USD 50 / hour"}
               ]
             }
           ]

    # Version 1 is gone from the decision's reach: 409 with where it is now.
    assert Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 1}, @now) ==
             {:error, {:approval_not_pending, %{state: :pending, version: 2}}}

    # The requester revises while it waits: version 3 with a new file, the bid carried.
    portfolio = attachment(c.fiza_s, "Portfolio links\n", "portfolio.txt")

    {:ok, a} =
      Act.revise(c.fiza_s, a.id, %{body_md: "Final words.", media_ids: [portfolio.id]}, @now)

    assert %{version: 3, current: %{proposed: %{bid: %{min_minor: 5000}}, attachments: [file]}} =
             a

    assert file.media_id == portfolio.id
    assert [%{field: "body_md"}] = a.diff

    # Each version still holds its own files.
    stored = Data.Approvals.get_for_system(a.id)

    assert Enum.map(stored.versions, fn v -> Enum.map(v.media_links, & &1.media_id) end) ==
             [[rate_card.id], [rate_card.id], [portfolio.id]]

    {:ok, a} = Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 3}, @now)
    assert %{state: :approved, effect: %{state: :ready}} = a
    assert a.effect.words == "Approved: ready to send. The bid is stored on the lead."

    lead = Data.Leads.reload(c.lead)

    assert {lead.bid_minor, lead.bid_currency, lead.bid_period, lead.connects_spent} ==
             {5000, "USD", :hour, 12}

    # A ledger row per ask (v1, v2, v3) and one for the outcomes.
    assert length(events(lead.id, :approval_requested)) == 3
    assert [_changes, _approved] = events(lead.id, :approval_decided)

    {:ok, a} = Act.sent(c.fiza_s, a.id, @now)
    assert a.effect == %{state: :sent, words: "Recorded as sent."}
  end

  test "drafting follows the customer's policy; refusals are field errors; a draft is the requester's",
       c do
    assert {:error, {:invalid, %{"slots" => ["says who decides"]}}} =
             ask(c, c.fiza_s, %{approval_kind: "other"})

    assert {:error, {:invalid, %{"proposed.bid_minor" => ["doesn't fit a reply"]}}} =
             ask(c, c.fiza_s, %{approval_kind: "reply", proposed: %{bid_minor: 100}})

    assert {:error, {:invalid, %{"proposed.document_id" => ["is required"]}}} =
             ask(c, c.fiza_s, %{approval_kind: "cv_for_job"})

    assert {:error, {:invalid, %{"team_id" => ["isn't its team"]}}} =
             ask(c, c.fiza_s, %{approval_kind: "rate", team_id: c.frontend.id})

    assert {:error, {:invalid, %{"rule" => ["follows the customer's rules"]}}} =
             ask(c, c.fiza_s, %{
               approval_kind: "cv_for_job",
               proposed: %{document_id: c.cv.id},
               rule: "all"
             })

    # Under *any*, a named person could approve without the customer: refused (AQ-07's run).
    assert {:error,
            {:invalid, %{"slots" => ["can't add a person here: Tanweer's rules say who decides"]}}} =
             ask(c, c.fiza_s, %{
               approval_kind: "cv_for_job",
               proposed: %{document_id: c.cv.id},
               slots: [%{slot: "user", user_id: c.bilal.id}]
             })

    {:ok, a} =
      ask(c, c.fiza_s, %{
        approval_kind: "cv_for_job",
        title: "CV for Bamboo",
        proposed: %{document_id: c.cv.id},
        due_at: "2026-11-19T12:00:00Z"
      })

    assert a.state == :draft
    assert Enum.map(a.slots, & &1.slot) == [:customer]
    assert a.can.submit and a.can.edit and not a.can.decide

    # Nobody is told of a draft; the customer and Qasim can't see it, a team lead can.
    assert notices(c.tanweer.user_id |> Data.Accounts.get_user(), a.id) == []
    assert Approvals.get(c.tanweer_s, a.id, @now) == {:error, :not_found}
    assert Approvals.get(scope_for(c.qasim), a.id, @now) == {:error, :not_found}
    assert {:ok, _} = Approvals.get(scope_for(c.hira), a.id, @now)

    {:ok, a} = Approvals.edit(c.fiza_s, a.id, %{title: "CV for Bamboo (v4)", slots: []}, @now)
    assert a.title == "CV for Bamboo (v4)" and Enum.map(a.slots, & &1.slot) == [:customer]

    {:ok, a} = Act.submit(c.fiza_s, a.id, @now)
    assert a.state == :pending and a.submitted_at == @now

    assert {:error, {:invalid, %{"state" => _}}} =
             Approvals.edit(c.fiza_s, a.id, %{title: "x"}, @now)

    assert {:ok, %{can: %{decide: true, comment: true, edit: false}}} =
             Approvals.get(c.tanweer_s, a.id, @now)
  end

  test "all over customer and team lead: one yes waits; not_reviewer; the note; then Copy → Recorded as sent",
       c do
    policy_fixture(c.tanweer, approval_kind: :reply, needs: :both, rule: :all)
    conv = conversation_fixture(c.fiza_s, lead: c.lead)
    mei = contact_fixture(c.fiza_s, name: "Mei Chen")

    asked =
      message_fixture(c.fiza_s, conversation: conv, contact: mei, body_text: "Are you free?")

    {:ok, a} =
      Approvals.draft(
        c.fiza_s,
        %{
          team_id: c.backend.id,
          approval_kind: "reply",
          title: "Reply to Mei",
          message_id: asked.id,
          body_md: "Yes, Tuesday works.",
          submit: true
        },
        @now
      )

    assert a.lead.id == c.lead.id and a.rule == :all
    assert Enum.map(a.slots, & &1.slot) == [:customer, :team_lead]

    assert Act.decide(scope_for(c.qasim), a.id, %{decision: "approved", version: 1}, @now) ==
             {:error, :not_reviewer}

    assert Act.decide(c.fiza_s, a.id, %{decision: "approved", version: 1}, @now) ==
             {:error, :not_reviewer}

    {:ok, a} = Act.decide(scope_for(c.hira), a.id, %{decision: "approved", version: 1}, @now)
    assert a.state == :pending
    assert [%{slot: :customer}] = a.waiting_on
    assert [%{person: nil, open: true}, %{person: %{name: "Hira Khan"}, open: false}] = a.slots

    assert {:error, {:invalid, %{"note" => ["is required"]}}} =
             Act.decide(c.tanweer_s, a.id, %{decision: "rejected", version: 1}, @now)

    # Hira's slot has decided this version: a second word from her is stale.
    assert {:error, {:approval_not_pending, %{state: :pending, version: 1}}} =
             Act.decide(scope_for(c.bilal), a.id, %{decision: "approved", version: 1}, @now)

    {:ok, a} = Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 1}, @now)
    assert %{state: :approved, effect: %{state: :ready, words: "Approved: ready to send."}} = a
    assert a.can.decide == false

    {:ok, a} = Act.sent(c.fiza_s, a.id, @now)
    assert a.effect.state == :sent

    sent =
      Repo.one(from(m in Data.Conversations.Message, where: m.parent_message_id == ^asked.id))

    assert %{direction: :out, captured_via: :manual, body_text: "Yes, Tuesday works."} = sent
    assert sent.conversation_id == conv.id

    assert {:error, {:invalid, %{"effect" => _}}} = Act.sent(c.fiza_s, a.id, @now)
  end

  test "comments: one stream for every party, the others told, the author's to delete", c do
    {:ok, a} =
      ask(c, c.fiza_s, %{
        approval_kind: "cv_for_job",
        title: "CV for Bamboo",
        proposed: %{document_id: c.cv.id},
        submit: true
      })

    {:ok, comment} = Comments.create(c.tanweer_s, a.id, %{body_md: "Is this the latest?"}, @now)

    assert %{body_md: "Is this the latest?", author: %{name: "Tanweer"}, can: %{delete: true}} =
             comment

    assert [
             %{
               notification_kind_key: "approvals.commented",
               title: "Tanweer commented on CV for Bamboo"
             }
           ] =
             notices(c.fiza, a.id)
             |> Enum.filter(&(&1.notification_kind_key == "approvals.commented"))

    assert {:ok, [%{can: %{delete: false}}]} = Comments.list(scope_for(c.qasim), a.id)
    assert {:ok, [%{can: %{delete: true}}]} = Comments.list(scope_for(c.bilal), a.id)
    assert {:error, {:forbidden, _}} = Comments.delete(scope_for(c.qasim), comment.id, @now)
    assert :ok = Comments.delete(c.tanweer_s, comment.id, @now)
    assert {:ok, [%{deleted: true, body_md: ""}]} = Comments.list(c.fiza_s, a.id)
    assert {:ok, %{comments_count: 0}} = Approvals.get(c.fiza_s, a.id, @now)
    assert Comments.list(customer_scope_for(c.naveed), a.id) == {:error, :not_found}
  end
end
