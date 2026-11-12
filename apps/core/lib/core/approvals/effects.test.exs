defmodule Core.Approvals.EffectsTest do
  @moduledoc """
  AQ-07 P7.2–P7.3 through the contexts: every kind's effect through the
  existing verbs (the CV by P4a's `cv`, the bid, the expectation and the
  letter by P4a's `edit`, the pitch and skills by P1's writes on the
  requester's behalf), an effect that can't apply, the page and its tabs,
  the lead's tab and *Next*, and the policies.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Approvals
  alias Core.Approvals.{Act, Policies}
  alias Core.Customers.Profiles
  alias Core.Leads.Change
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

  test "the CV for a job: approved by the customer, set through P4a's cv on Fiza's behalf", c do
    {:ok, a} =
      ask(c, c.fiza_s, %{
        approval_kind: "cv_for_job",
        title: "CV for Bamboo",
        proposed: %{document_id: c.cv.id},
        submit: true
      })

    tanweer = Data.Accounts.get_user(c.tanweer.user_id)

    assert [%{notification_kind_key: "approvals.requested", title: title, actor_user_id: actor}] =
             notices(tanweer, a.id)

    assert title == "Fiza asks for your approval: CV for Bamboo"
    assert actor == c.fiza.id
    assert notices(c.fiza, a.id) == []

    assert [%{visibility: :customer, to_label: "CV for Bamboo", approval_id: approval_id}] =
             events(c.lead.id, :approval_requested)

    assert approval_id == a.id

    {:ok, a} = Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 1}, @now)

    assert a.effect == %{
             state: :applied,
             words: "Approved. Golang v4 is now the CV for this lead."
           }

    assert Data.Leads.reload(c.lead).document_id == c.cv.id

    assert [%{to_label: "Golang v4", note: "Approved by Tanweer", actor_user_id: by}] =
             events(c.lead.id, :cv_set)

    assert by == c.fiza.id

    assert [%{to_label: "Approved", visibility: :customer}] = events(c.lead.id, :approval_decided)

    assert [
             %{
               notification_kind_key: "approvals.decided",
               title: "Tanweer approved CV for Bamboo"
             }
           ] = notices(c.fiza, a.id)

    assert {:ok, %{waiting_on_me: 0}} = Approvals.count(c.tanweer_s, %{})
  end

  test "the rate is set; the cover letter by a named person; an asset by a team lead; other withdrawn",
       c do
    # Qasim and Muaz work Fiza's lead: the team's peers may edit (P4a's rule for asking).
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})

    {:ok, rate} =
      ask(c, scope_for(c.qasim), %{
        approval_kind: "rate",
        proposed: %{
          expectation_minor: 9_000_000,
          expectation_currency: "USD",
          expectation_period: "year"
        },
        submit: true
      })

    {:ok, rate} =
      Act.decide(
        c.tanweer_s,
        rate.id,
        %{decision: "rejected", note: "Too high.", version: 1},
        @now
      )

    assert rate.state == :rejected and rate.effect.state == :none
    assert Data.Leads.reload(c.lead).expectation_minor == nil

    {:ok, rate} =
      ask(c, c.fiza_s, %{
        approval_kind: "rate",
        proposed: %{
          expectation_minor: 8_000_000,
          expectation_currency: "USD",
          expectation_period: "year"
        },
        submit: true
      })

    {:ok, rate} = Act.decide(c.tanweer_s, rate.id, %{decision: "approved", version: 1}, @now)
    assert rate.effect.state == :applied
    assert Data.Leads.reload(c.lead).expectation_minor == 8_000_000

    {:ok, letter} =
      ask(c, c.fiza_s, %{
        approval_kind: "cover_letter",
        body_md: "Dear Bamboo, …",
        slots: [%{slot: "user", user_id: c.bilal.id}],
        submit: true
      })

    assert {:ok, %{waiting_on_me: 1}} = Approvals.count(scope_for(c.bilal), %{})

    {:ok, letter} =
      Act.decide(scope_for(c.bilal), letter.id, %{decision: "approved", version: 1}, @now)

    assert letter.effect.state == :ready
    assert Data.Leads.reload(c.lead).cover_letter_md == "Dear Bamboo, …"

    pdf = attachment(scope_for(c.muaz), "Case study\n", "case-study.txt")

    {:ok, asset} =
      ask(c, scope_for(c.muaz), %{
        approval_kind: "asset",
        media_ids: [pdf.id],
        slots: [%{slot: "team_lead"}],
        submit: true
      })

    # A team-lead-only ask is staff business: the ledger row is staff's.
    assert [%{visibility: :staff}] =
             Enum.filter(events(c.lead.id, :approval_requested), &(&1.approval_id == asset.id))

    {:ok, asset} =
      Act.decide(scope_for(c.hira), asset.id, %{decision: "approved", version: 1}, @now)

    assert asset.effect == %{state: :applied, words: "Approved. Its files are on the lead."}

    {:ok, other} =
      ask(c, scope_for(c.hira), %{
        approval_kind: "other",
        slots: [%{slot: "user", user_id: c.dawud.id}],
        submit: true
      })

    assert Act.withdraw(scope_for(c.qasim), other.id, @now) ==
             {:error, {:forbidden, "Only whoever asked, or a team lead, can change this."}}

    {:ok, other} = Act.withdraw(scope_for(c.hira), other.id, @now)
    assert other.state == :withdrawn
    assert [%{approval_id: id}] = events(c.lead.id, :approval_withdrawn)
    assert id == other.id
  end

  test "a profile change asked by a member applies the pitch and skills; they still can't edit it",
       c do
    go = skill_fixture(c.org, name: "Go")
    pg = skill_fixture(c.org, name: "PostgreSQL")
    muaz = scope_for(c.muaz)

    assert {:error, {:forbidden, _}} =
             Profiles.update_pitch(muaz, c.golang.id, %{"title" => "Go engineer"})

    {:ok, a} =
      Approvals.draft(
        muaz,
        %{
          team_id: c.backend.id,
          approval_kind: "profile_change",
          title: "A sharper pitch",
          profile_id: c.golang.id,
          body_md: "Leads with Go.",
          proposed: %{
            title: "Go engineer",
            headline: "Go and Postgres",
            summary: "Ten years.",
            skill_ids: [go.id, pg.id]
          },
          submit: true
        },
        @now
      )

    assert a.lead == nil and a.profile.title == "Golang backend"
    assert Enum.map(a.current.proposed.skills, & &1.name) == ["Go", "PostgreSQL"]

    {:ok, a} = Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 1}, @now)
    assert a.effect.state == :applied

    profile = Data.Profiles.get(c.golang.id)

    assert {profile.title, profile.headline, profile.summary_md} ==
             {"Go engineer", "Go and Postgres", "Ten years."}

    assert profile.profile_skills |> Enum.map(& &1.skill_id) |> Enum.sort() ==
             Enum.sort([go.id, pg.id])

    assert {:error, {:forbidden, _}} =
             Profiles.update_pitch(muaz, c.golang.id, %{"title" => "Mine"})

    # Imran is served by Frontend alone; Backend's staff can't ask about him.
    imran_profile = profile_fixture(c.imran, title: "AI engineer")

    assert {:error, :not_found} =
             Approvals.draft(
               muaz,
               %{
                 team_id: c.backend.id,
                 approval_kind: "profile_change",
                 title: "x",
                 profile_id: imran_profile.id,
                 proposed: %{title: "y"}
               },
               @now
             )
  end

  test "an effect that can't apply: the decision stands, the effect failed with the reason", c do
    {:ok, a} =
      ask(c, c.fiza_s, %{
        approval_kind: "cv_for_job",
        title: "CV for Bamboo",
        proposed: %{document_id: c.cv.id},
        submit: true
      })

    {:ok, _archived} = Change.flag(c.fiza_s, :archive, c.lead.id, @now)
    {:ok, a} = Act.decide(c.tanweer_s, a.id, %{decision: "approved", version: 1}, @now)

    assert %{state: :approved, effect: %{state: :failed, words: words}} = a
    assert words == "Approved, but couldn't apply: the lead is archived."
    assert Data.Leads.reload(c.lead).document_id != c.cv.id
  end

  test "the page: waiting on me, I asked, all (a team lead's), the customer's; the lead's tab",
       c do
    {:ok, cv} =
      ask(c, c.fiza_s, %{
        approval_kind: "cv_for_job",
        title: "CV for Bamboo",
        proposed: %{document_id: c.cv.id},
        submit: true,
        due_at: "2026-11-13T12:00:00Z"
      })

    {:ok, asset} =
      ask(c, c.fiza_s, %{approval_kind: "asset", slots: [%{slot: "team_lead"}], submit: true})

    page = fn scope, params ->
      elem(Approvals.list(scope, params, @now), 1).items |> Enum.map(& &1.id)
    end

    assert page.(c.tanweer_s, %{}) == [cv.id]
    assert page.(scope_for(c.hira), %{"team_id" => c.backend.id}) == [asset.id]

    assert Enum.sort(page.(c.fiza_s, %{"team_id" => c.backend.id, "tab" => "asked"})) ==
             Enum.sort([cv.id, asset.id])

    assert page.(scope_for(c.hira), %{
             "team_id" => c.backend.id,
             "tab" => "all",
             "kind" => "cv_for_job"
           }) == [cv.id]

    assert Approvals.list(c.fiza_s, %{"team_id" => c.backend.id, "tab" => "all"}, @now) ==
             {:error, {:forbidden, "Only a team lead can see all of the team's approvals."}}

    assert {:ok, %{waiting_on_me: 1}} =
             Approvals.count(scope_for(c.hira), %{"team_id" => c.backend.id})

    assert {:ok, rows} = Approvals.for_lead(c.tanweer_s, c.lead.id, @now)
    assert Enum.map(rows, & &1.id) == [cv.id]
    assert {:ok, staff_rows} = Approvals.for_lead(scope_for(c.qasim), c.lead.id, @now)
    assert length(staff_rows) == 2

    {:ok, sheet} = Core.Leads.get(c.fiza_s, c.lead.id, @now)
    assert sheet.tabs.approvals == 2

    assert %{kind: "approval", words: "Approval · CV for Bamboo · due Fri", approval_id: id} =
             sheet.next

    assert id == cv.id
  end

  test "policies: Q12's defaults as code, a team lead's override, back to the default", c do
    {:ok, rows} = Policies.list(scope_for(c.qasim), c.tanweer.id)

    assert Enum.map(rows, & &1.approval_kind) ==
             ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)a

    assert Enum.map(rows, &{&1.needs, &1.rule, &1.auto_approve_hours, &1.is_default}) ==
             [{:team_lead, :any, nil, true}] ++
               List.duplicate({:customer, :any, nil, true}, 2) ++
               [
                 {:ad_hoc, :any, nil, true},
                 {:customer, :any, nil, true},
                 {:ad_hoc, :any, nil, true}
               ] ++
               [{:customer, :any, nil, true}, {:ad_hoc, :any, nil, true}]

    assert Policies.put(
             scope_for(c.qasim),
             c.tanweer.id,
             "reply",
             %{needs: "both", rule: "all"},
             @now
           ) ==
             {:error, {:forbidden, "Only a team lead can change approval rules."}}

    assert {:error, {:invalid, %{"auto_approve_hours" => _}}} =
             Policies.put(
               scope_for(c.bilal),
               c.tanweer.id,
               "rate",
               %{needs: "customer", rule: "any", auto_approve_hours: 5},
               @now
             )

    assert {:ok,
            %{
              approval_kind: :reply,
              needs: :both,
              rule: :all,
              auto_approve_hours: 24,
              is_default: false
            }} =
             Policies.put(
               scope_for(c.bilal),
               c.tanweer.id,
               "reply",
               %{needs: "both", rule: "all", auto_approve_hours: 24},
               @now
             )

    assert Policies.list(scope_for(c.hira), c.imran.id) |> elem(1) |> hd() |> Map.get(:is_default)
    assert Policies.list(scope_for(c.bilal), c.imran.id) == {:error, :not_found}
    assert Policies.list(c.tanweer_s, c.tanweer.id) == {:error, :not_found}

    assert :ok = Policies.reset(scope_for(c.dawud), c.tanweer.id, "reply", @now)

    assert {:ok, [%{is_default: true, needs: :team_lead} | _]} =
             Policies.list(scope_for(c.bilal), c.tanweer.id)
  end
end
