defmodule Core.Tasks.PartsTest do
  @moduledoc "A task's parts (AQ-02 §7.2, §7.3): checklist, steps and *Nudge*, links, relations, files, people, stages."

  use Core.CoreCase, async: true

  alias Core.Tasks
  alias Core.Tasks.{Checklist, Files, Links, People, Stages, Steps}
  alias Data.Notifications
  alias Data.TaskHistories

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup c do
    c = Map.merge(c, board_cast_fixture())

    task =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :assigned,
        primary: c.fiza
      )

    Map.put(c, :task, task)
  end

  defp lines(task, field),
    do: for(h <- TaskHistories.list(task.id), h.field == field, do: {h.from_label, h.to_label})

  defp titles(user, task), do: user.id |> Notifications.for_task(task.id) |> Enum.map(& &1.title)

  test "the checklist: add, rename, tick (staff, and the customer given it), remove, reorder",
       c do
    fiza = scope_for(c.fiza)
    {:ok, _sheet} = Checklist.add(fiza, c.task.id, %{"text" => "Export"}, @now)
    {:ok, sheet} = Checklist.add(fiza, c.task.id, %{"text" => "Upload"}, @now)
    [one, two] = sheet.checklist

    assert {:ok, _sheet} =
             Checklist.rename(fiza, c.task.id, one.id, %{"text" => "Export as PDF"}, @now)

    tanweer = customer_scope_for(c.tanweer)

    assert {:ok, %{checklist: [%{checked_at: @now}, _two]}} =
             Checklist.toggle(tanweer, c.task.id, one.id, @now)

    assert {:ok, %{progress: %{checklist: %{done: 1, total: 2}}}} =
             Tasks.get(fiza, c.task.id, @now)

    assert {:error, {:invalid, _}} = Checklist.reorder(fiza, c.task.id, [two.id], @now)

    assert {:ok, %{checklist: [%{id: first} | _]}} =
             Checklist.reorder(fiza, c.task.id, [two.id, one.id], @now)

    assert first == two.id
    assert {:ok, %{checklist: [_one]}} = Checklist.remove(fiza, c.task.id, two.id, @now)

    assert lines(c.task, :checklist) == [
             {"Upload", nil},
             {"☐ Export as PDF", "☑ Export as PDF"},
             {"Export", "Export as PDF"},
             {nil, "Upload"},
             {nil, "Export"}
           ]

    shared =
      task_fixture(scope_for(c.hira),
        team: c.backend,
        customer: c.tanweer,
        customer_access: :shared,
        checklist: ["x"]
      )

    [item] = Data.Repo.preload(shared, :checklist_items).checklist_items

    assert {:error, {:forbidden, "This task isn't yours to do."}} =
             Checklist.toggle(tanweer, shared.id, item.id, @now)
  end

  test "steps: the assignee told, a step for the customer needs one, its assignee ticks it, a nudge once a day",
       c do
    hira = scope_for(c.hira)

    {:ok, sheet} =
      Steps.add(
        hira,
        c.task.id,
        %{"title" => "Record a 2-minute intro", "assignee_user_id" => c.muaz.id},
        @now
      )

    [step] = sheet.steps
    assert titles(c.muaz, c.task) == ["Hira gave you “Record a 2-minute intro”"]

    personal = task_fixture(hira)

    assert {:error, {:forbidden, "This task isn't about a customer."}} =
             Steps.add(hira, personal.id, %{"title" => "x", "is_for_customer" => true}, @now)

    assert {:ok, %{steps: [%{done_at: @now, done_by: %{name: "Muaz"}}]}} =
             Steps.toggle(scope_for(c.muaz), c.task.id, step.id, @now)

    assert {:ok, _sheet} = Steps.toggle(scope_for(c.muaz), c.task.id, step.id, @now)

    assert {:ok, _sheet} = Steps.nudge(hira, c.task.id, step.id, @now)
    assert {:ok, _sheet} = Steps.nudge(hira, c.task.id, step.id, DateTime.add(@now, 1, :hour))
    assert {:ok, _sheet} = Steps.nudge(hira, c.task.id, step.id, DateTime.add(@now, 1, :day))
    nudges = Enum.filter(titles(c.muaz, c.task), &String.contains?(&1, "nudged"))

    assert nudges == [
             "Hira nudged you about “Record a 2-minute intro”",
             "Hira nudged you about “Record a 2-minute intro”"
           ]

    {:ok, sheet} =
      Steps.add(hira, c.task.id, %{"title" => "Confirm Tuesday", "is_for_customer" => true}, @now)

    yours = Enum.find(sheet.steps, & &1.is_for_customer)
    tanweer = customer_scope_for(c.tanweer)
    assert {:error, {:forbidden, _}} = Steps.toggle(tanweer, c.task.id, step.id, @now)
    assert {:ok, %{steps: steps}} = Steps.toggle(tanweer, c.task.id, yours.id, @now)
    assert Enum.find(steps, & &1.yours).done_at == @now

    assert {:ok, %{steps: [_one]}} = Steps.remove(hira, c.task.id, step.id, @now)
  end

  test "links are http and https only; relations read from both ends, relates_to once per pair",
       c do
    hira = scope_for(c.hira)
    other = task_fixture(hira, team: c.backend, title: "Shortlist")

    assert {:ok, %{links: [%{label: "linkedin.com", url: "https://www.linkedin.com/jobs/1"}]}} =
             Links.add_link(hira, c.task.id, %{"url" => "https://www.linkedin.com/jobs/1"}, @now)

    assert {:error, %Ecto.Changeset{}} =
             Links.add_link(hira, c.task.id, %{"url" => "javascript:alert(1)"}, @now)

    assert {:ok,
            %{relations: [%{kind: :blocks, direction: "outgoing", task: %{title: "Shortlist"}}]}} =
             Links.add_relation(
               hira,
               c.task.id,
               %{"task_id" => other.id, "kind" => "blocks"},
               @now
             )

    assert {:ok, %{relations: [%{direction: "incoming"}]}} = Tasks.get(hira, other.id, @now)

    assert {:ok, _sheet} =
             Links.add_relation(
               hira,
               c.task.id,
               %{"task_id" => other.id, "kind" => "relates_to"},
               @now
             )

    assert {:error, %Ecto.Changeset{}} =
             Links.add_relation(
               hira,
               other.id,
               %{"task_id" => c.task.id, "kind" => "relates_to"},
               @now
             )

    hidden = task_fixture(scope_for(c.hira), team: c.frontend)

    assert {:error, :not_found} =
             Links.add_relation(
               scope_for(c.bilal),
               c.task.id,
               %{"task_id" => hidden.id, "kind" => "blocks"},
               @now
             )

    # A relation names a task only to those who may open it.
    assert {:ok, _sheet} =
             Links.add_relation(
               hira,
               c.task.id,
               %{"task_id" => hidden.id, "kind" => "duplicates"},
               @now
             )

    assert {:ok, %{relations: relations}} = Tasks.get(scope_for(c.bilal), c.task.id, @now)
    refute Enum.any?(relations, &(&1.task.id == hidden.id))
  end

  test "files: the caller's own confirmed attachment, added and removed, in the activity", c do
    fiza = scope_for(c.fiza)

    params = %{
      "media_kind" => "attachment",
      "content_type" => "text/plain",
      "byte_count" => 5,
      "original_filename" => "cv.txt"
    }

    {:ok, media, _target} = Core.Media.create(fiza, params, "/media")
    :ok = Core.Media.store(fiza, media.id, "hello")
    {:ok, _confirmed} = Core.Media.confirm(fiza, media.id, %{}, @now)

    assert {:error, :not_found} =
             Files.add(scope_for(c.hira), c.task.id, %{"media_id" => media.id}, @now)

    assert {:ok,
            %{
              files: [%{id: id, original_filename: "cv.txt", added_by: %{name: "Fiza"}}],
              file_count: 1
            }} =
             Files.add(fiza, c.task.id, %{"media_id" => media.id}, @now)

    assert id == media.id
    assert {:ok, %{files: []}} = Files.remove(fiza, c.task.id, media.id, @now)
    assert lines(c.task, :file) == [{"cv.txt", nil}, {nil, "cv.txt"}]
  end

  test "people: new assignees told, the stage goes with the primary, watching and muting", c do
    hira = scope_for(c.hira)
    {:ok, stage} = Data.TaskStages.create(c.fiza.id, "Sourcing")

    {:ok, _sheet} =
      Tasks.Act.run(hira, :start, c.task.id, %{"from" => "todo", "stage_id" => stage.id}, @now)

    assert {:ok, sheet} =
             People.put_assignees(
               hira,
               c.task.id,
               %{"primary_user_id" => c.qasim.id, "secondary_user_ids" => [c.fiza.id]},
               @now
             )

    assert [%{name: "Qasim", level: :primary}, %{name: "Fiza", level: :secondary}] = sheet.people
    assert sheet.stage == nil
    assert titles(c.qasim, c.task) == ["Hira gave you “#{c.task.title}”"]
    assert titles(c.fiza, c.task) == []
    assert lines(c.task, :assignees) == [{"Fiza", "Fiza and Qasim"}]

    assert {:error, :not_found} =
             People.put_assignees(hira, c.task.id, %{"primary_user_id" => c.imran.user_id}, @now)

    assert {:ok, %{me_on: %{watching: true, muted: false}, watchers: [%{name: "Hira Khan"}]}} =
             People.watch(hira, c.task.id, true, @now)

    assert {:ok, %{me_on: %{watching: true, muted: true}}} =
             People.mute(hira, c.task.id, "true", @now)

    assert {:error, {:forbidden, _}} =
             People.watch(customer_scope_for(c.tanweer), c.task.id, true, @now)
  end

  test "stages: each person's own, the four suggestions, in use, renamed, reordered, removed",
       c do
    fiza = scope_for(c.fiza)
    assert {:ok, %{stages: [], suggested: suggested}} = Stages.list(fiza)

    assert suggested == [
             "Sourcing",
             "Preparing",
             "Waiting on the customer",
             "Waiting on the recruiter"
           ]

    assert {:ok, %{stages: [%{name: "Sourcing"} = s, _p, _w, _r], suggested: []}} =
             Stages.create(fiza, %{"suggested" => true})

    assert {:error, %Ecto.Changeset{}} = Stages.create(fiza, %{"name" => "sourcing"})
    assert {:ok, %{stages: stages}} = Stages.rename(fiza, s.id, %{"name" => "Hunting"})
    assert {:ok, %{suggested: ["Sourcing"]}} = Stages.list(fiza)

    ids = stages |> Enum.map(& &1.id) |> Enum.reverse()
    assert {:ok, %{stages: reordered}} = Stages.reorder(fiza, ids)
    assert Enum.map(reordered, & &1.id) == ids

    assert {:error, :not_found} = Stages.rename(scope_for(c.qasim), s.id, %{"name" => "Mine"})
    assert {:error, :not_found} = Stages.list(customer_scope_for(c.tanweer))
    assert {:ok, %{stages: three}} = Stages.delete(fiza, s.id)
    assert length(three) == 3
  end
end
