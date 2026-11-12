defmodule Core.Tasks.DueTest do
  @moduledoc "Due reminders and overdue notices (AQ-02 §8, QP2-13): one scan that takes `now`, run twice, raising once."

  use Core.CoreCase, async: true

  alias Core.Tasks.Due
  alias Core.Workers.TaskDueScan
  alias Data.Notifications

  @now ~U[2026-11-10 10:00:00.000000Z]

  setup do: board_cast_fixture()

  defp told(user, task),
    do:
      user.id
      |> Notifications.for_task(task.id)
      |> Enum.map(&{&1.notification_kind_key, &1.title})

  test "the scan run twice raises once: overdue to the assignees and the customer given it", c do
    hira = scope_for(c.hira)
    due_at = DateTime.add(@now, -10, :minute)

    task =
      task_fixture(hira,
        team: c.backend,
        primary: c.muaz,
        customer: c.tanweer,
        customer_access: :assigned,
        due_at: due_at,
        title: "Call the recruiter"
      )

    first = Due.scan(@now)
    assert first >= 2
    assert Due.scan(@now) == 0

    assert told(c.muaz, task) == [{"tasks.overdue", "“Call the recruiter” is overdue"}]
    tanweer = Data.Accounts.get_user(c.tanweer.user_id)
    assert told(tanweer, task) == [{"tasks.overdue", "“Call the recruiter” is overdue"}]
    assert told(c.hira, task) == []
  end

  test "a reminder an hour before, in the reader's zone; nobody told of a draft, a done or an archived task",
       c do
    hira = scope_for(c.hira)
    due_at = ~U[2026-11-10 10:30:00.000000Z]

    soon =
      task_fixture(hira,
        team: c.backend,
        primary: c.fiza,
        due_at: due_at,
        reminder_minutes: 60,
        title: "Send CV"
      )

    task_fixture(hira,
      team: c.backend,
      primary: c.fiza,
      due_at: due_at,
      reminder_minutes: 60,
      state: :draft
    )

    task_fixture(hira,
      team: c.backend,
      primary: c.fiza,
      due_at: ~U[2026-11-01 10:00:00Z],
      state: :done
    )

    archived = task_fixture(hira, team: c.backend, primary: c.fiza, due_on: ~D[2026-11-01])
    {:ok, _archived} = Data.Tasks.archive(archived, @now, c.hira.id)

    Due.scan(@now)
    # Fiza's person keeps the default zone, Asia/Karachi: 10:30 UTC is 15:30 there.
    assert told(c.fiza, soon) == [{"tasks.due_soon", "“Send CV” is due at 15:30"}]
    assert Notifications.for_task(c.fiza.id, archived.id) == []
    assert Due.scan(DateTime.add(@now, 10, :minute)) == 0
  end

  test "overdue with no assignee tells the author; a muted assignee hears nothing", c do
    qasim = scope_for(c.qasim)
    alone = task_fixture(qasim, team: c.backend, due_on: ~D[2026-11-09])
    muted = task_fixture(qasim, team: c.backend, primary: c.muaz, due_on: ~D[2026-11-09])

    participant_mute =
      Data.Repo.get_by!(Data.Tasks.Participant, task_id: muted.id, user_id: c.muaz.id)

    Data.Repo.update!(Ecto.Changeset.change(participant_mute, is_muted: true))

    Due.scan(@now)
    assert [{"tasks.overdue", _title}] = told(c.qasim, alone)
    assert told(c.muaz, muted) == []
  end

  test "which notices are due is a pure function of the task, now and the zone" do
    task = %{due_at: ~U[2026-11-10 12:00:00Z], due_on: nil, reminder_minutes: 60}

    assert Due.due(task, ~U[2026-11-10 10:59:00Z], "Etc/UTC") == []
    assert Due.due(task, ~U[2026-11-10 11:00:00Z], "Etc/UTC") == [:due_soon]
    assert Due.due(task, ~U[2026-11-10 12:00:00Z], "Etc/UTC") == [:due_soon, :overdue]
    assert Due.due(task, ~U[2026-11-10 13:00:00Z], "Etc/UTC") == [:overdue]

    day = %{due_at: nil, due_on: ~D[2026-11-10], reminder_minutes: nil}
    assert Due.due(day, ~U[2026-11-10 18:59:00Z], "Asia/Karachi") == []
    assert Due.due(day, ~U[2026-11-10 19:00:00Z], "Asia/Karachi") == [:overdue]
  end

  test "the worker runs the scan, twice harmlessly, and the crontab names it every five minutes",
       c do
    task_fixture(scope_for(c.hira), team: c.backend, primary: c.fiza, due_on: ~D[2026-11-01])

    assert TaskDueScan.perform(%Oban.Job{args: %{}}) == :ok
    assert TaskDueScan.perform(%Oban.Job{args: %{}}) == :ok

    {Oban.Plugins.Cron, crontab: crontab} =
      :core
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> List.keyfind(Oban.Plugins.Cron, 0)

    assert {"*/5 * * * *", TaskDueScan} in crontab
    assert TaskDueScan.__opts__()[:queue] == :scheduling
  end
end
