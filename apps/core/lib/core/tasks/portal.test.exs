defmodule Core.Tasks.PortalTest do
  @moduledoc "The customer's board and the customer-made task's routing (AQ-02 §7.3, §9, QP2-3, QP2-4)."

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Notifications, as: Bell
  alias Core.Tasks
  alias Core.Tasks.{Act, Comments, Portal}
  alias Data.Customers.ProfileMember
  alias Data.Notifications

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp by_id(query), do: Repo.all(query)

  defp told(user, task_id),
    do:
      user.id
      |> Notifications.for_task(task_id)
      |> Enum.map(&{&1.notification_kind_key, &1.title})

  defp staff_sheet(c, id) do
    {:ok, sheet} = Tasks.get(scope_for(c.dawud), id, @now)
    sheet
  end

  describe "§9 routing" do
    test "a profile with two owners: both assigned, the earliest primary; the same day, the older row",
         c do
      # Fiza and Qasim took the profile the same day: the older row (the lower UUIDv7) is primary.
      [first, second] =
        by_id(
          from(m in ProfileMember,
            where: m.profile_id == ^c.golang.id,
            order_by: m.id,
            select: m.user_id
          )
        )

      assert {:ok, sheet} =
               Portal.create(
                 customer_scope_for(c.tanweer),
                 %{"title" => "Apply to the Stripe role I sent", "profile_id" => c.golang.id},
                 @now
               )

      assert sheet.on_it in ["Fiza and Qasim", "Qasim and Fiza"]
      assert sheet.made_by_you and not sheet.yours_to_do

      staff = staff_sheet(c, sheet.id)
      assert staff.team.id == c.backend.id
      assert staff.source == :customer and staff.customer_access == :shared

      assert [%{user_id: primary, level: :primary}, %{user_id: secondary, level: :secondary}] =
               staff.people

      assert {primary, secondary} == {first, second}
      refute staff.needs_owner

      words = "Tanweer added a task: “Apply to the Stripe role I sent”"
      assert told(c.fiza, sheet.id) == [{"tasks.customer_created", words}]
      assert told(c.qasim, sheet.id) == [{"tasks.customer_created", words}]
      assert told(c.hira, sheet.id) == []
    end

    test "an earlier owner is primary whatever the row order", c do
      for {later, earlier} <- [{c.qasim, c.fiza}, {c.fiza, c.qasim}] do
        Repo.update_all(from(m in ProfileMember, where: m.user_id == ^later.id),
          set: [since_on: ~D[2026-11-09]]
        )

        Repo.update_all(from(m in ProfileMember, where: m.user_id == ^earlier.id),
          set: [since_on: ~D[2026-01-01]]
        )

        {:ok, sheet} =
          Portal.create(
            customer_scope_for(c.tanweer),
            %{"title" => "x", "profile_id" => c.golang.id},
            @now
          )

        assert [%{user_id: primary, level: :primary} | _rest] = staff_sheet(c, sheet.id).people
        assert primary == earlier.id
      end
    end

    test "no profile: nobody assigned, the team's leads told, the card needs an owner", c do
      {:ok, sheet} =
        Portal.create(
          customer_scope_for(c.tanweer),
          %{"title" => "Stop applying to agencies"},
          @now
        )

      staff = staff_sheet(c, sheet.id)
      assert staff.people == [] and staff.needs_owner
      assert sheet.on_it == nil
      assert [{"tasks.customer_created", _words}] = told(c.hira, sheet.id)
      assert [{"tasks.customer_created", _words}] = told(c.bilal, sheet.id)
      assert told(c.dawud, sheet.id) == []
      assert told(c.fiza, sheet.id) == []
    end

    test "a customer in no team cannot add one: every task is in a team (AQ-03B)", c do
      lone = customer_fixture(c.org, [], display_name: "Lone", login: true)

      assert {:error, {:forbidden, "No team serves you yet" <> _rest}} =
               Portal.create(customer_scope_for(lone), %{"title" => "Anyone?"}, @now)
    end

    test "two teams, no owner in either: the first by name; an owner's team wins (AQ-03B §5.1)",
         c do
      both = customer_fixture(c.org, [c.frontend, c.backend], display_name: "Both", login: true)

      {:ok, sheet} = Portal.create(customer_scope_for(both), %{"title" => "Which team?"}, @now)
      assert staff_sheet(c, sheet.id).team.id == c.backend.id

      design =
        profile_fixture(both,
          title: "Design",
          owners: [user_fixture() |> then(&member_fixture(c.frontend, :member, &1))]
        )

      {:ok, later} =
        Portal.create(
          customer_scope_for(both),
          %{"title" => "And now?", "profile_id" => design.id},
          @now
        )

      assert staff_sheet(c, later.id).team.id == c.frontend.id
    end

    test "someone else's profile is not found", c do
      theirs = profile_fixture(c.naveed, title: "Elixir")

      assert {:error, :not_found} =
               Portal.create(
                 customer_scope_for(c.tanweer),
                 %{"title" => "x", "profile_id" => theirs.id},
                 @now
               )

      assert {:error, :not_found} = Portal.create(scope_for(c.hira), %{"title" => "x"}, @now)
    end
  end

  test "the board: waiting on you, with the team, done; staff-only and drafts never there", c do
    hira = scope_for(c.hira)

    given =
      task_fixture(hira,
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned,
        primary: c.fiza
      )

    stepped = task_fixture(hira, team: c.backend, customer: c.tanweer, customer_access: :shared)
    step_fixture(stepped, is_for_customer: true)
    shared = task_fixture(hira, team: c.backend, customer: c.tanweer, customer_access: :shared)

    done =
      task_fixture(hira,
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        state: :done
      )

    task_fixture(hira, team: c.backend, customer: c.tanweer)

    task_fixture(hira,
      team: c.backend,
      customer: c.tanweer,
      customer_access: :shared,
      state: :draft
    )

    assert {:ok, board} = Portal.board(customer_scope_for(c.tanweer), @now)

    assert board.waiting_on_you |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([given.id, stepped.id])

    assert Enum.map(board.with_team, & &1.id) == [shared.id]
    assert Enum.map(board.done, & &1.id) == [done.id]
    assert board.older_done == 0 and board.empty == false

    assert [%{on_it: "Fiza", people: [%{name: "Fiza"}]}] =
             Enum.filter(board.waiting_on_you, &(&1.id == given.id))

    Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    assert {:ok, board} = Portal.board(customer_scope_for(c.tanweer), @now)

    assert [%{on_it: "The team", people: []}] =
             Enum.filter(board.waiting_on_you, &(&1.id == given.id))

    assert {:ok, %{empty: true}} = Portal.board(customer_scope_for(c.naveed), @now)
  end

  test "a customer edits their own task while it is To do, and nothing else", c do
    tanweer = customer_scope_for(c.tanweer)
    {:ok, sheet} = Portal.create(tanweer, %{"title" => "Apply"}, @now)

    given =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned
      )

    assert {:ok, %{title: "Apply to Stripe"}} =
             Portal.update(
               tanweer,
               sheet.id,
               %{"title" => "Apply to Stripe", "team_id" => c.frontend.id},
               @now
             )

    assert {:error, {:forbidden, _words}} =
             Portal.update(tanweer, given.id, %{"title" => "Mine now"}, @now)
  end

  test "the customer reopens a task given to them that is done, never one the team closed", c do
    tanweer = customer_scope_for(c.tanweer)

    given =
      &task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned,
        state: &1
      )

    done = given.(:done)
    closed = given.(:closed)

    assert {:ok, %{state: :todo}} =
             Act.portal(tanweer, :reopen, done.id, %{"from" => "done"}, @now)

    assert {:error, {:invalid, %{"state" => [_words]}}} =
             Act.portal(tanweer, :reopen, closed.id, %{"from" => "closed"}, @now)
  end

  test "the customer reads staff by first name in the bell; the team reads the customer by the customer's name",
       c do
    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        primary: c.fiza
      )

    assert {:ok, _thread} =
             Comments.create(
               scope_for(c.fiza),
               task.id,
               %{"body" => "On it", "is_staff_only" => false},
               @now
             )

    assert {:ok, %{items: [%{actor: %{name: "Fiza"}, title: "Fiza commented on “" <> _rest}]}} =
             Bell.page(customer_scope_for(c.tanweer), %{})

    assert {:ok, _thread} =
             Comments.create(
               customer_scope_for(c.tanweer),
               task.id,
               %{"body" => "Thanks!"},
               @now
             )

    assert {:ok, %{items: [%{title: "Tanweer commented on “" <> _rest} | _older]}} =
             Bell.page(scope_for(c.fiza), %{})
  end
end
