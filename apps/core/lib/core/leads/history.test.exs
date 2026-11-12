defmodule Core.Leads.HistoryTest do
  @moduledoc """
  AQ-04B §8.1: History, newest first, keyset pages, `kind` as a comma list;
  whoever reads the lead reads it; the customer reads theirs in the portal.
  And the tasks on a lead (QP4b-14): `task_created` and `task_done`,
  customer-visible when the task is shown to the customer.
  """

  use Core.CoreCase, async: true

  alias Core.Leads.{History, Notes}
  alias Core.Tasks.Act, as: TaskAct
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.put(c, :lead, lead)
  end

  defp at(n), do: DateTime.add(@now, n, :second)

  test "newest first, in pages, narrowed by kind", c do
    for n <- 1..3,
        do: {:ok, _} = Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "N#{n}"}, at(n))

    assert {:ok, %{items: [newest | _] = items, next_cursor: nil}} =
             History.page(scope_for(c.hira), c.lead.id, %{})

    assert newest.note == "N3" and length(items) == 3

    assert {:ok, %{items: [_, _, _]}} =
             History.page(scope_for(c.hira), c.lead.id, %{"kind" => "note_added,applied"})

    {:ok, %{items: [first, second | _]}} =
      History.page(scope_for(c.hira), c.lead.id, %{"kind" => "note_added"})

    assert {:ok, %{items: [after_first | _]}} =
             History.page(scope_for(c.hira), c.lead.id, %{
               "kind" => "note_added",
               "before" => first.id
             })

    assert after_first.id == second.id

    assert History.page(scope_for(c.hira), c.lead.id, %{"kind" => "nope"}) ==
             {:error, {:invalid, %{"kind" => ["has a value that is not one of the list"]}}}
  end

  test "keyset pages of fifty", c do
    for n <- 1..55,
        do:
          Store.add_event(%{
            organisation_id: c.lead.organisation_id,
            lead_id: c.lead.id,
            kind: :follow_up_due,
            occurred_at: at(n),
            recorded_at: at(n),
            actor_kind: :system,
            visibility: :staff
          })

    {:ok, %{items: page, next_cursor: before}} = History.page(scope_for(c.fiza), c.lead.id, %{})
    assert length(page) == 50 and before == List.last(page).id

    {:ok, %{items: rest, next_cursor: nil}} =
      History.page(scope_for(c.fiza), c.lead.id, %{"before" => before})

    assert length(rest) == 5
  end

  test "a reader of the lead reads it; another team's member and the customer do not", c do
    farah = member_fixture(c.frontend, :member, user_fixture())
    assert History.page(scope_for(farah), c.lead.id, %{}) == {:error, :not_found}
    assert History.page(customer_scope_for(c.tanweer), c.lead.id, %{}) == {:error, :not_found}
  end

  describe "tasks on a lead" do
    test "Add task on the lead: in its team, about its customer and profile; task_created", c do
      {:ok, task} =
        Core.Tasks.create(
          scope_for(c.fiza),
          %{
            "title" => "Send the portfolio link",
            "team_id" => c.backend.id,
            "lead_id" => c.lead.id,
            "customer_access" => "shared",
            "due_on" => "2026-11-12"
          },
          @now
        )

      stored = Repo.get!(Data.Tasks.Task, task.id)
      assert stored.lead_id == c.lead.id and stored.customer_id == c.tanweer.id
      assert stored.profile_id == c.golang.id

      [created | _] = Store.events(c.lead.id)
      assert created.kind == :task_created and created.visibility == :customer
      assert created.to_label == "Send the portfolio link" and created.task_id == task.id

      {:ok, sheet} = Core.Leads.get(scope_for(c.fiza), c.lead.id, @now)
      assert [%{id: id}] = sheet.tasks
      assert id == task.id
      assert sheet.next.words == "Task · Send the portfolio link · due Thu"

      {:ok, portal} = Core.Leads.get(customer_scope_for(c.tanweer), c.lead.id, @now)
      assert [%{title: "Send the portfolio link"}] = portal.tasks
      assert Enum.any?(portal.events, &(&1.kind == :task_created))

      {:ok, _} = TaskAct.run(scope_for(c.fiza), :done, task.id, %{"from" => "todo"}, @now)
      [done | _] = Store.events(c.lead.id)
      assert done.kind == :task_done and done.visibility == :customer
    end

    test "a staff-only task's events are staff; the portal lists no such task", c do
      {:ok, task} =
        Core.Tasks.create(
          scope_for(c.fiza),
          %{"title" => "Internal", "team_id" => c.backend.id, "lead_id" => c.lead.id},
          @now
        )

      [created | _] = Store.events(c.lead.id)
      assert created.visibility == :staff and created.task_id == task.id

      {:ok, portal} = Core.Leads.get(customer_scope_for(c.tanweer), c.lead.id, @now)
      assert portal.tasks == []
    end

    test "a lead in another team, or one the caller may not change, refuses the task", c do
      assert Core.Tasks.create(
               scope_for(c.hira),
               %{"title" => "X", "team_id" => c.frontend.id, "lead_id" => c.lead.id},
               @now
             ) ==
               {:error,
                {:invalid,
                 %{"lead_id" => ["is in another team: a task on a lead is in the lead's team"]}}}

      {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

      assert Core.Tasks.create(
               scope_for(c.muaz),
               %{"title" => "X", "team_id" => c.backend.id, "lead_id" => c.lead.id},
               @now
             ) ==
               {:error,
                {:forbidden, "You can see this, but only its owner or a team lead can change it."}}

      assert {:error, {:invalid, %{"customer_id" => _}}} =
               Core.Tasks.create(
                 scope_for(c.fiza),
                 %{
                   "title" => "X",
                   "team_id" => c.backend.id,
                   "lead_id" => c.lead.id,
                   "customer_id" => c.naveed.id
                 },
                 @now
               )
    end

    test "a purged lead unlinks its task, never deletes it", c do
      task =
        task_fixture(scope_for(c.fiza), team: c.backend, customer: c.tanweer, lead_id: c.lead.id)

      {:ok, _} = Repo.delete(Store.reload(c.lead))
      assert Repo.get!(Data.Tasks.Task, task.id).lead_id == nil
    end
  end
end
