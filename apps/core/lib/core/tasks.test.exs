defmodule Core.TasksTest do
  @moduledoc "A task made, read, edited, archived and deleted (AQ-02 §7.2), with QP2-11's audit rows only."

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Tasks
  alias Core.Tasks.{Act, People}
  alias Data.Audit.AuditEvent
  alias Data.Notifications
  alias Data.TaskHistories

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp audit(task_id),
    do:
      Repo.all(
        from(e in AuditEvent,
          where: e.subject_id == ^task_id,
          order_by: e.occurred_at,
          select: e.action
        )
      )

  defp titles(user, task_id),
    do: user.id |> Notifications.for_task(task_id) |> Enum.map(& &1.title)

  describe "create" do
    test "a team task with people, a checklist and steps: logged, audited, its people told", c do
      params = %{
        "title" => "Upload the updated CV",
        "team_id" => c.backend.id,
        "customer_id" => c.tanweer.id,
        "profile_id" => c.golang.id,
        "customer_access" => "assigned",
        "due_at" => "2026-11-11T10:00:00Z",
        "reminder_minutes" => 60,
        "primary_user_id" => c.fiza.id,
        "secondary_user_ids" => [c.qasim.id],
        "checklist" => ["Export as PDF", "Upload"],
        "steps" => [%{"title" => "Record a 2-minute intro", "is_for_customer" => true}]
      }

      assert {:ok, sheet} = Tasks.create(scope_for(c.hira), params, @now)
      assert sheet.customer_access == :assigned

      assert [%{name: "Fiza", level: :primary}, %{name: "Qasim", level: :secondary}] =
               sheet.people

      assert sheet.progress.checklist == %{done: 0, total: 2}
      assert sheet.can.move and sheet.customer_sees

      assert titles(c.fiza, sheet.id) == ["Hira gave you “Upload the updated CV”"]
      assert titles(user(c.tanweer), sheet.id) == ["Hira gave you “Upload the updated CV”"]
      assert audit(sheet.id) == ["created"]
      assert [%{field: :created, to_label: "To do"}] = TaskHistories.list(sheet.id)
    end

    test "§6.2's refusals in words; a customer of another team, or a stranger, refused", c do
      hira = scope_for(c.hira)

      # AQ-03B §5.1: every task names its team, and `is_private` is gone.
      assert {:error, {:invalid, %{"team_id" => ["is required"]}}} =
               Tasks.create(hira, %{"title" => "x"}, @now)

      assert {:error, {:invalid, %{"is_private" => [_gone]}}} =
               Tasks.create(
                 hira,
                 %{"title" => "x", "team_id" => c.backend.id, "is_private" => true},
                 @now
               )

      assert {:error, :not_found} =
               Tasks.create(hira, %{"title" => "x", "team_id" => Ecto.UUID.generate()}, @now)

      assert {:error, {:forbidden, "This task isn't about a customer."}} =
               Tasks.create(
                 hira,
                 %{
                   "title" => "x",
                   "team_id" => c.backend.id,
                   "steps" => [%{"title" => "s", "is_for_customer" => true}]
                 },
                 @now
               )

      assert {:error, {:invalid, %{"customer_id" => _}}} =
               Tasks.create(
                 hira,
                 %{"title" => "x", "team_id" => c.backend.id, "customer_id" => c.imran.id},
                 @now
               )

      assert {:error, :not_found} =
               Tasks.create(
                 hira,
                 %{
                   "title" => "x",
                   "team_id" => c.backend.id,
                   "primary_user_id" => user(c.tanweer).id
                 },
                 @now
               )

      assert {:error, :not_found} =
               Tasks.create(
                 scope_for(c.muaz),
                 %{"title" => "x", "team_id" => c.frontend.id},
                 @now
               )

      assert {:error, %Ecto.Changeset{}} =
               Tasks.create(hira, %{"title" => " ", "team_id" => c.backend.id}, @now)
    end

    test "a draft tells nobody", c do
      assert {:ok, sheet} =
               Tasks.create(
                 scope_for(c.hira),
                 %{
                   "title" => "Think",
                   "state" => "draft",
                   "team_id" => c.backend.id,
                   "primary_user_id" => c.fiza.id
                 },
                 @now
               )

      assert sheet.state == :draft
      assert titles(c.fiza, sheet.id) == []
    end
  end

  describe "update" do
    test "one history group; audited only when who sees it changes; the customer told when given it",
         c do
      task =
        task_fixture(scope_for(c.hira), team: c.backend, customer: c.tanweer, primary: c.fiza)

      hira = scope_for(c.hira)

      assert {:ok, _sheet} =
               Tasks.update(
                 hira,
                 task.id,
                 %{"title" => "Shortlist ten Go roles", "priority" => "high"},
                 @now
               )

      assert audit(task.id) == []
      groups = task.id |> TaskHistories.list() |> Enum.map(& &1.change_group_id) |> Enum.uniq()
      assert length(groups) == 1

      assert {:ok, %{customer_access: :assigned}} =
               Tasks.update(hira, task.id, %{"customer_access" => "assigned"}, @now)

      assert audit(task.id) == ["visibility_changed"]
      assert titles(user(c.tanweer), task.id) == ["Hira gave you “Shortlist ten Go roles”"]
    end

    test "an assignee who is a member changes the task, but not who sees it", c do
      task =
        task_fixture(scope_for(c.hira), team: c.backend, customer: c.tanweer, primary: c.fiza)

      fiza = scope_for(c.fiza)

      assert {:ok, %{due_on: ~D[2026-11-12]}} =
               Tasks.update(fiza, task.id, %{"due_on" => "2026-11-12"}, @now)

      assert {:error, {:forbidden, "Only the task's author or a lead can change who sees it."}} =
               Tasks.update(fiza, task.id, %{"customer_access" => "shared"}, @now)
    end

    test "the team stays (QT-12): the same team_id is harmless, another is a field error; is_private too",
         c do
      hira = scope_for(c.hira)
      task = task_fixture(hira, team: c.backend)

      assert {:ok, %{team: %{id: same}}} =
               Tasks.update(hira, task.id, %{"team_id" => c.backend.id, "title" => "Kept"}, @now)

      assert same == c.backend.id

      assert {:error, {:invalid, %{"team_id" => ["can't be moved to another team"]}}} =
               Tasks.update(hira, task.id, %{"team_id" => c.frontend.id}, @now)

      assert {:error, {:invalid, %{"is_private" => [_gone]}}} =
               Tasks.update(hira, task.id, %{"is_private" => false}, @now)
    end
  end

  describe "archive, unarchive, delete" do
    test "archive hides and is recoverable; a draft is deleted by its author only; each audited",
         c do
      hira = scope_for(c.hira)
      task = task_fixture(hira, team: c.backend)
      draft = task_fixture(hira, team: c.backend, state: :draft)

      assert {:ok, %{id: id}} = Act.archive(hira, task.id, @now)
      assert id == task.id
      assert {:ok, []} = Tasks.search(hira, task.title)
      assert {:ok, _sheet} = Act.unarchive(hira, task.id, @now)
      assert audit(task.id) == ["archived", "unarchived"]

      assert {:error, {:forbidden, "Only a draft can be deleted. Archive it instead."}} =
               Act.delete(hira, task.id, @now)

      assert {:error, :not_found} = Act.delete(scope_for(c.bilal), draft.id, @now)
      assert :ok = Act.delete(hira, draft.id, @now)
      assert Tasks.get(hira, draft.id, @now) == {:error, :not_found}
      assert List.last(audit(draft.id)) == "deleted"
    end
  end

  test "search is the relation picker: the caller's live tasks; nothing for the portal", c do
    task =
      task_fixture(scope_for(c.fiza),
        team: c.backend,
        title: "Shortlist ten Go roles",
        primary: c.fiza
      )

    assert {:ok, [%{id: id, title: "Shortlist ten Go roles", state: :todo}]} =
             Tasks.search(scope_for(c.hira), "go roles")

    assert id == task.id
    assert {:ok, [_peer_at_view]} = Tasks.search(scope_for(c.muaz), "go roles")
    Data.Teams.put_settings(c.backend.id, %{peer_tasks: :hidden})
    assert {:ok, []} = Tasks.search(scope_for(c.muaz), "go roles")
    assert {:error, :not_found} = Tasks.search(customer_scope_for(c.tanweer), "go")
  end

  test "the customer's activity is §6.4's: no stage, priority or private; assignees in their words",
       c do
    hira = scope_for(c.hira)
    task = task_fixture(hira, team: c.backend, customer: c.tanweer)

    {:ok, _sheet} =
      Tasks.update(hira, task.id, %{"priority" => "urgent", "title" => "Apply today"}, @now)

    {:ok, _sheet} = Tasks.update(hira, task.id, %{"customer_access" => "shared"}, @now)

    {:ok, _sheet} =
      People.put_assignees(hira, task.id, %{"primary_user_id" => c.fiza.id}, @now)

    assert {:ok, staff} = Tasks.history(hira, task.id)
    assert staff |> Enum.flat_map(& &1.lines) |> Enum.map(& &1.field) |> Enum.member?(:priority)

    assert {:ok, groups} = Tasks.history(customer_scope_for(c.tanweer), task.id)
    lines = Enum.flat_map(groups, & &1.lines)
    refute Enum.any?(lines, &(&1.field in [:priority, :stage, :private, :team]))
    assert %{to_label: "Fiza is on it"} = Enum.find(lines, &(&1.field == :assignees))

    assert %{to_label: "Tanweer sees this task"} =
             Enum.find(lines, &(&1.field == :customer_access))

    Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    assert {:ok, groups} = Tasks.history(customer_scope_for(c.tanweer), task.id)

    assert %{to_label: "The team is on it"} =
             groups |> Enum.flat_map(& &1.lines) |> Enum.find(&(&1.field == :assignees))

    assert Enum.all?(groups, &(&1.actor.name == "The team"))
  end

  defp user(customer), do: Data.Accounts.get_user(customer.user_id)
end
