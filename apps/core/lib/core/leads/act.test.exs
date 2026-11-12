defmodule Core.Leads.ActTest do
  @moduledoc """
  Every verb of AQ-04A §7 with its rules and refusals: `from` and the 409
  `lead_moved`, apply and apply again (one row, a second `applied` event,
  the team's leads told), any stage after any other, hold with a reason and
  resume to the same stage, finish with its outcomes (Hired pins, Position
  closed closes the job, To do only Not pursued or Position closed), reopen
  where it finished, and the customer's notices in their words.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Leads
  alias Core.Leads.Act
  alias Core.Leads.Change
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()

    job =
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        title: "Backend Developer",
        company: company_fixture(c.org, name: "Bamboo Invest")
      )

    Map.put(c, :job, job)
  end

  defp saved(c, as \\ "save") do
    {:ok, sheet} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => c.job.id, "profile_id" => c.golang.id, "as" => as},
        @now
      )

    sheet
  end

  defp seen(sheet),
    do: %{"state" => to_string(sheet.state), "stage" => sheet.stage && sheet.stage.key}

  defp run(who, verb, sheet, params \\ %{}),
    do: Act.run(who, verb, sheet.id, Map.put_new(params, "from", seen(sheet)), @now)

  defp kinds(lead_id), do: lead_id |> Store.events() |> Enum.map(& &1.kind) |> Enum.reverse()

  defp notified(user_id, kind) do
    Repo.all(
      from(n in Data.Notifications.Notification,
        where: n.user_id == ^user_id and n.notification_kind_key == ^kind,
        order_by: n.inserted_at
      )
    )
  end

  test "from is required, and a stale one is the 409 with where the lead is now", c do
    sheet = saved(c)
    fiza = scope_for(c.fiza)
    assert Act.run(fiza, :apply, sheet.id, %{}, @now) == {:error, {:missing, [:from]}}

    {:ok, applied} = run(fiza, :apply, sheet)

    assert {:error, {:lead_moved, lead}} = run(scope_for(c.hira), :apply, sheet)
    assert lead.state == :in_progress and lead.stage.key == "applied"

    assert {:error, {:lead_moved, _}} =
             Act.run(
               fiza,
               :move,
               applied.id,
               %{"from" => %{"state" => "in_progress", "stage" => "offer"}, "state" => "on_hold"},
               @now
             )
  end

  test "apply from To do: Applied, the owner and the customer told in their words", c do
    sheet = saved(c)
    {:ok, applied} = run(scope_for(c.hira), :apply, sheet, %{"applied_via" => "referral"})
    assert applied.state == :in_progress and applied.stage.key == "applied"
    assert applied.applied_via == :referral and applied.applied_by.user_id == c.hira.id
    assert kinds(sheet.id) == [:saved, :applied]

    assert [%{title: "Hira moved “Backend Developer · Bamboo Invest” to Applied."}] =
             notified(c.fiza.id, "leads.moved")

    # Backend squad shows staff names to the customer until a lead turns it off.
    assert [%{title: title}] = notified(c.tanweer.user_id, "leads.customer_update")
    assert title == "Hira applied to “Backend Developer” at Bamboo Invest as “Golang backend”."
  end

  test "the customer reads \"The team\" when the team hides staff names", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    _sheet = saved(c, "apply")

    assert [%{title: title, actor_user_id: nil}] =
             notified(c.tanweer.user_id, "leads.customer_update")

    assert title ==
             "The team applied to “Backend Developer” at Bamboo Invest as “Golang backend”."
  end

  test "move: any stage after any other, an interview revisited; a stage of another version is refused",
       c do
    sheet = saved(c, "apply")
    fiza = scope_for(c.fiza)

    lead =
      Enum.reduce(
        ~w(recruiter_screen technical_1 technical_2 technical_1 offer recruiter_contact),
        sheet,
        fn key, lead ->
          {:ok, moved} = run(fiza, :move, lead, %{"state" => "in_progress", "stage" => key})
          assert moved.stage.key == key
          moved
        end
      )

    assert Enum.count(kinds(sheet.id), &(&1 == :stage_moved)) == 6

    assert {:error, {:invalid, %{"stage" => _}}} =
             run(fiza, :move, lead, %{"state" => "in_progress", "stage" => "contract_started"})

    assert {:error, {:missing, [:stage]}} = run(fiza, :move, lead, %{"state" => "in_progress"})

    assert {:ok, same} =
             run(fiza, :move, lead, %{"state" => "in_progress", "stage" => "recruiter_contact"})

    assert same.stage.key == "recruiter_contact"
    assert {:error, {:invalid, %{"state" => _}}} = run(fiza, :move, lead, %{"state" => "todo"})
  end

  test "a drop from To do into In progress is an application", c do
    sheet = saved(c)

    {:ok, moved} =
      run(scope_for(c.fiza), :move, sheet, %{"state" => "in_progress", "stage" => "technical_1"})

    assert moved.stage.key == "technical_1" and moved.applied_at
    assert kinds(sheet.id) == [:saved, :applied]
  end

  test "hold asks for a reason, keeps the stage, takes an until day; resume returns to the stage",
       c do
    sheet = saved(c, "apply")
    fiza = scope_for(c.fiza)
    {:ok, at_t1} = run(fiza, :move, sheet, %{"state" => "in_progress", "stage" => "technical_1"})

    assert run(fiza, :hold, at_t1) == {:error, {:missing, [:hold_reason]}}
    assert {:error, {:missing, [:hold_reason]}} = run(fiza, :move, at_t1, %{"state" => "on_hold"})

    assert {:error, {:invalid, %{"hold_until_on" => _}}} =
             run(fiza, :hold, at_t1, %{"hold_reason" => "Visa", "hold_until_on" => "soon"})

    {:ok, held} =
      run(fiza, :hold, at_t1, %{
        "hold_reason" => "Waiting for the visa",
        "hold_until_on" => "2026-11-12"
      })

    assert held.state == :on_hold and held.stage.key == "technical_1"
    assert held.hold_reason == "Waiting for the visa" and held.hold_until_on == ~D[2026-11-12]
    refute held.resume_due

    # The day comes: *Resume?* on the card (the organisation's day).
    {:ok, later} = Leads.get(fiza, held.id, ~U[2026-11-12 10:00:00Z])
    assert later.resume_due

    assert {:error, {:invalid, %{"state" => _}}} =
             run(fiza, :hold, held, %{"hold_reason" => "again"})

    {:ok, resumed} = run(fiza, :resume, held)
    assert resumed.state == :in_progress and resumed.stage.key == "technical_1"
    assert resumed.hold_reason == nil and resumed.hold_until_on == nil

    [hold_event | _] = sheet.id |> Store.events() |> Enum.filter(&(&1.to_label == "On hold"))
    assert hold_event.note == "Waiting for the visa" and hold_event.visibility == :customer
  end

  test "finish: an outcome is required; Hired pins; the stage reached is kept; another lead never moves",
       c do
    sheet = saved(c, "apply")
    other_profile = profile_fixture(c.tanweer, title: "Elixir backend")

    {:ok, other} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => c.job.id, "profile_id" => other_profile.id, "as" => "apply"},
        @now
      )

    fiza = scope_for(c.fiza)
    {:ok, at_t2} = run(fiza, :move, sheet, %{"state" => "in_progress", "stage" => "technical_2"})

    assert run(fiza, :finish, at_t2) == {:error, :outcome_required}
    assert {:error, :outcome_required} = run(fiza, :move, at_t2, %{"state" => "done"})

    assert {:error, {:invalid, %{"outcome" => _}}} =
             run(fiza, :finish, at_t2, %{"outcome" => "not_pursued"})

    {:ok, hired} =
      run(fiza, :finish, at_t2, %{"outcome" => "hired", "outcome_note" => "Start in December"})

    assert hired.state == :done and hired.outcome == :hired and hired.is_pinned
    assert hired.stage.key == "technical_2" and hired.outcome_note == "Start in December"
    assert Store.get(c.org.id, other.id).state == :in_progress

    {:ok, reopened} = run(fiza, :reopen, hired)
    assert reopened.state == :in_progress and reopened.stage.key == "technical_2"
    assert reopened.outcome == nil and reopened.is_pinned

    {:ok, rejected} = run(fiza, :finish, reopened, %{"outcome" => "rejected"})
    assert rejected.outcome == :rejected

    assert [%{from_label: "In progress · Technical interview 2", to_label: "Rejected"} | _] =
             sheet.id |> Store.events() |> Enum.filter(&(&1.kind == :outcome_set))
  end

  test "from To do only Not pursued or Position closed; reopening returns to To do", c do
    sheet = saved(c)
    fiza = scope_for(c.fiza)

    assert {:error, {:invalid, %{"outcome" => _}}} =
             run(fiza, :finish, sheet, %{"outcome" => "rejected"})

    {:ok, dropped} = run(fiza, :finish, sheet, %{"outcome" => "not_pursued"})
    assert dropped.state == :done and dropped.stage == nil and dropped.applied_at == nil

    {:ok, back} = run(fiza, :reopen, dropped)
    assert back.state == :todo and back.outcome == nil
  end

  test "Position closed closes the job too, with P3's audit row, unless close_job is false", c do
    sheet = saved(c, "apply")
    {:ok, closed} = run(scope_for(c.fiza), :finish, sheet, %{"outcome" => "position_closed"})
    assert closed.outcome == :position_closed
    assert Data.Jobs.get(c.org.id, c.job.id).status == :closed

    assert Enum.any?(
             Data.Audit.list_for_subject(c.org.id, "jobs", c.job.id),
             &(&1.action == "closed")
           )

    job2 = job_fixture(scope_for(c.fiza), team: c.backend)

    {:ok, s2} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job2.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    {:ok, _} =
      run(scope_for(c.fiza), :finish, s2, %{"outcome" => "position_closed", "close_job" => false})

    assert Data.Jobs.get(c.org.id, job2.id).status == :open
  end

  test "apply again: a reason is required; one row, a second applied event, the hold cleared, the team's leads told",
       c do
    sheet = saved(c, "apply")
    fiza = scope_for(c.fiza)
    {:ok, held} = run(fiza, :hold, sheet, %{"hold_reason" => "Form broke"})
    {:ok, archived} = Change.flag(fiza, :archive, held.id, @now)

    assert run(fiza, :apply_again, archived) == {:error, :override_reason_required}

    {:ok, again} =
      run(fiza, :apply_again, archived, %{
        "reason" => "The first application failed with a form error"
      })

    assert again.state == :in_progress and again.stage.key == "applied"
    assert again.archived_at == nil and again.hold_reason == nil
    assert length(Store.for_jobs([c.job.id])) == 1

    applied = sheet.id |> Store.events() |> Enum.filter(&(&1.kind == :applied))
    assert length(applied) == 2

    assert [
             %{is_again: true, note: "The first application failed with a form error"},
             %{is_again: false}
           ] = applied

    for lead <- [c.hira, c.bilal] do
      assert [%{body: "The first application failed with a form error", title: title}] =
               notified(lead.id, "leads.applied_again")

      assert title =~ "Fiza applied again as “Golang backend”"
    end

    assert notified(c.fiza.id, "leads.applied_again") == []

    assert {:error, {:invalid, %{"state" => _}}} =
             run(fiza, :apply_again, saved(%{c | job: job_fixture(fiza, team: c.backend)}), %{
               "reason" => "x"
             })
  end

  test "an archived lead does not move until unarchived", c do
    sheet = saved(c, "apply")
    {:ok, archived} = Change.flag(scope_for(c.fiza), :archive, sheet.id, @now)

    assert {:error, {:invalid, %{"state" => _}}} =
             run(scope_for(c.fiza), :hold, archived, %{"hold_reason" => "x"})
  end

  test "a person's event moves the lead's and the job's activity", c do
    sheet = saved(c)
    later = ~U[2026-11-12 09:00:00.000000Z]
    {:ok, _} = Act.run(scope_for(c.fiza), :apply, sheet.id, %{"from" => seen(sheet)}, later)
    assert DateTime.compare(Store.get(c.org.id, sheet.id).last_activity_at, later) == :eq
    assert DateTime.compare(Data.Jobs.get(c.org.id, c.job.id).last_activity_at, later) == :eq
  end

  test "the customer's I applied: To do only, the owner told, the event the customer's", c do
    sheet = saved(c)
    tanweer = customer_scope_for(c.tanweer)

    {:ok, view} =
      Act.portal_applied(
        tanweer,
        sheet.id,
        %{"from" => seen(sheet), "applied_via" => "in_platform_easy"},
        @now
      )

    assert view.state == :in_progress and view.stage.key == "applied" and
             view.can == %{applied: false}

    lead = Store.get(c.org.id, sheet.id)
    assert lead.applied_by_user_id == c.tanweer.user_id and lead.applied_confirmation == :by_hand
    assert [%{actor_kind: :customer} | _] = Store.events(lead.id)

    assert [%{title: "Tanweer moved “Backend Developer · Bamboo Invest” to Applied."}] =
             notified(c.fiza.id, "leads.moved")

    assert notified(c.tanweer.user_id, "leads.customer_update") == []

    assert Act.portal_applied(
             tanweer,
             sheet.id,
             %{"from" => %{"state" => "in_progress", "stage" => "applied"}},
             @now
           ) ==
             {:error, {:forbidden, "You can say you applied while it is still To do."}}

    assert Act.portal_applied(
             customer_scope_for(c.naveed),
             sheet.id,
             %{"from" => seen(sheet)},
             @now
           ) == {:error, :not_found}
  end
end
