defmodule Core.Tasks.ActTest do
  @moduledoc "The verbs (AQ-02 §7.2): each move checked against `from`, logged, told, in one transaction."

  use Core.CoreCase, async: true

  alias Core.Tasks.{Act, Histories, Notices, Steps, Write}
  alias Data.Notifications
  alias Data.TaskHistories
  alias Data.TaskStages

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp fields(task_id), do: task_id |> TaskHistories.list() |> Enum.map(& &1.field)
  defp titles(user, task), do: user.id |> Notifications.for_task(task.id) |> Enum.map(& &1.title)

  test "start, hold, resume, done, reopen, close: each a history group, Done told to the others",
       c do
    task = task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza, watchers: [c.qasim])
    fiza = scope_for(c.fiza)

    assert {:ok, %{state: :in_progress}} =
             Act.run(fiza, :start, task.id, %{"from" => "todo"}, @now)

    assert {:error, {:missing, :reason}} =
             Act.run(fiza, :hold, task.id, %{"from" => "in_progress"}, @now)

    assert {:ok, held} =
             Act.run(
               fiza,
               :hold,
               task.id,
               %{"from" => "in_progress", "reason" => "The new CV"},
               @now
             )

    assert held.hold == %{reason: "The new CV", at: @now}
    assert held.held_from_state == :in_progress

    assert {:ok, %{state: :in_progress, hold: nil}} =
             Act.run(fiza, :resume, task.id, %{"from" => "on_hold"}, @now)

    assert {:ok, %{state: :done, done_at: @now}} =
             Act.run(fiza, :done, task.id, %{"from" => "in_progress"}, @now)

    title = "Fiza marked “#{task.title}” done"
    assert titles(c.hira, task) == [title]
    assert titles(c.qasim, task) == [title]
    assert titles(c.fiza, task) == []

    assert {:ok, %{state: :todo, done_at: nil}} =
             Act.run(fiza, :reopen, task.id, %{"from" => "done"}, @now)

    assert {:error, {:invalid, %{"reason" => _}}} =
             Act.run(fiza, :close, task.id, %{"from" => "todo", "reason" => "withdrawn"}, @now)

    assert {:ok, closed} =
             Act.run(
               fiza,
               :close,
               task.id,
               %{"from" => "todo", "reason" => "wont_do", "note" => "Agency"},
               @now
             )

    assert closed.closed == %{reason: :wont_do, note: "Agency", at: @now}
    assert fields(task.id) |> Enum.count(&(&1 == :state)) == 6
  end

  test "a move against a state that changed answers task_moved with where it is now", c do
    task = task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza, state: :in_progress)

    assert {:error, {:task_moved, moved}} =
             Act.run(scope_for(c.fiza), :done, task.id, %{"from" => "todo"}, @now)

    assert moved.state == :in_progress
    assert {:error, {:missing, :from}} = Act.run(scope_for(c.fiza), :done, task.id, %{}, @now)

    assert {:error, {:invalid, %{"state" => [_words]}}} =
             Act.run(scope_for(c.fiza), :reopen, task.id, %{"from" => "in_progress"}, @now)
  end

  test "a drop: any column, a reason for On hold and Closed, a stage of the primary's", c do
    task = task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza)
    {:ok, sourcing} = TaskStages.create(c.fiza.id, "Sourcing")
    {:ok, hiras} = TaskStages.create(c.hira.id, "Mine")
    hira = scope_for(c.hira)

    assert {:error, {:invalid, %{"stage_id" => _}}} =
             Act.run(
               hira,
               :move,
               task.id,
               %{"from" => "todo", "state" => "in_progress", "stage_id" => hiras.id},
               @now
             )

    assert {:ok, %{state: :in_progress, stage: %{name: "Sourcing"}}} =
             Act.run(
               hira,
               :move,
               task.id,
               %{"from" => "todo", "state" => "in_progress", "stage_id" => sourcing.id},
               @now
             )

    assert {:error, {:missing, :reason}} =
             Act.run(hira, :move, task.id, %{"from" => "in_progress", "state" => "closed"}, @now)

    assert {:ok, %{state: :done}} =
             Act.run(hira, :move, task.id, %{"from" => "in_progress", "state" => "done"}, @now)

    stages =
      for h <- TaskHistories.list(task.id), h.field == :stage, do: {h.from_label, h.to_label}

    assert stages == [{"Sourcing", nil}, {nil, "Sourcing"}]
  end

  test "a draft tells nobody, is its author's alone, and tells its people when it becomes real",
       c do
    hira = scope_for(c.hira)
    task = task_fixture(hira, team: c.backend, primary: c.fiza, state: :draft)
    step_fixture(task, assignee: c.muaz, title: "Record a 2-minute intro")

    assert {:error, :not_found} =
             Act.run(scope_for(c.fiza), :start, task.id, %{"from" => "draft"}, @now)

    assert {:ok, %{state: :todo}} =
             Act.run(hira, :move, task.id, %{"from" => "draft", "state" => "todo"}, @now)

    assert titles(c.fiza, task) == ["Hira gave you “#{task.title}”"]
    assert titles(c.muaz, task) == ["Hira gave you “Record a 2-minute intro”"]

    assert {:error, {:forbidden, "Only its author can put a task back in Drafts."}} =
             Act.run(
               scope_for(c.bilal),
               :move,
               task.id,
               %{"from" => "todo", "state" => "draft"},
               @now
             )

    assert {:ok, %{state: :draft}} =
             Act.run(hira, :move, task.id, %{"from" => "todo", "state" => "draft"}, @now)
  end

  test "a drop on the column it is in changes nothing", c do
    task = task_fixture(scope_for(c.hira), team: c.backend)
    before = length(TaskHistories.list(task.id))

    assert {:ok, %{state: :todo}} =
             Act.run(
               scope_for(c.hira),
               :move,
               task.id,
               %{"from" => "todo", "state" => "todo"},
               @now
             )

    assert length(TaskHistories.list(task.id)) == before
  end

  test "a rolled-back verb writes no history and no notification", c do
    hira = scope_for(c.hira)
    task = task_fixture(hira, team: c.backend, primary: c.fiza)

    assert {:error, %Ecto.Changeset{}} =
             Steps.add(hira, task.id, %{"title" => "  ", "assignee_user_id" => c.muaz.id}, @now)

    result =
      Write.commit(fn ->
        line = Histories.line(:title, "a", "b", "a", "b")
        :ok = Histories.write(hira, task.id, Histories.group_id(), [line], @now)
        _told = Notices.assigned(hira, task, [c.muaz.id], Histories.group_id())
        {:error, :boom}
      end)

    assert result == {:error, :boom}
    assert fields(task.id) == []
    assert titles(c.muaz, task) == []
  end

  test "the customer marks done what was given to them, reopens it, and withdraws their own", c do
    tanweer = customer_scope_for(c.tanweer)

    given =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned
      )

    shared =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared
      )

    own = task_fixture(tanweer, team: c.backend)

    assert {:ok, %{state: :done}} =
             Act.portal(tanweer, :done, given.id, %{"from" => "todo"}, @now)

    assert titles(c.hira, given) == ["Tanweer marked “#{given.title}” done"]

    assert {:ok, %{state: :todo}} =
             Act.portal(tanweer, :reopen, given.id, %{"from" => "done"}, @now)

    assert {:error, {:forbidden, "This task isn't yours to do."}} =
             Act.portal(tanweer, :done, shared.id, %{"from" => "todo"}, @now)

    assert {:error, {:forbidden, _words}} =
             Act.portal(tanweer, :withdraw, shared.id, %{"from" => "todo"}, @now)

    assert {:ok, %{state: :closed, closed: %{reason: :withdrawn}}} =
             Act.portal(tanweer, :withdraw, own.id, %{"from" => "todo"}, @now)
  end
end
