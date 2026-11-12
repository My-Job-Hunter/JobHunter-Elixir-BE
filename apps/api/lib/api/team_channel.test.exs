defmodule Api.TeamChannelTest do
  @moduledoc "`team:<id>` (AQ-02 §7.4): the team's open members and the admins; created, updated, deleted, ids only."

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian
  alias Core.Leads.Act, as: LeadAct
  alias Core.Leads.Change
  alias Core.Organisation.Teams
  alias Core.Tasks.Act

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  test "a member and an admin join; someone of another team, a customer, a stranger are refused",
       c do
    topic = "team:" <> c.backend.id
    assert {:ok, _reply, _socket} = subscribe_and_join(socket_for(c.muaz), Api.TeamChannel, topic)

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(c.dawud), Api.TeamChannel, "team:" <> c.frontend.id)

    for user <- [c.muaz, Data.Accounts.get_user(c.imran.user_id), user_fixture()] do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket_for(user), Api.TeamChannel, "team:" <> c.frontend.id)
    end
  end

  test "hears a task made, moved and archived on the team, by id", c do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(c.muaz), Api.TeamChannel, "team:" <> c.backend.id)

    hira = scope_for(c.hira)

    {:ok, sheet} =
      Core.Tasks.create(hira, %{"title" => "Shortlist", "team_id" => c.backend.id}, @now)

    id = sheet.id
    assert_push "task_created", %{task: ^id}

    {:ok, _sheet} = Act.run(hira, :start, id, %{"from" => "todo"}, @now)
    assert_push "task_updated", %{task: ^id}

    {:ok, _sheet} = Act.archive(hira, id, @now)
    assert_push "task_deleted", %{task: ^id}

    # Another team's task is not heard here.
    {:ok, _sheet} =
      Core.Tasks.create(hira, %{"title" => "Elsewhere", "team_id" => c.frontend.id}, @now)

    refute_push "task_created", _payload

    # A rolled-back move says nothing.
    {:error, _reason} = Act.run(hira, :hold, id, %{"from" => "in_progress"}, @now)
    refute_push "task_updated", _payload
  end

  test "hears a change of the team's settings, so an open board re-reads (§12 step 2)", c do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(c.muaz), Api.TeamChannel, "team:" <> c.backend.id)

    team = c.backend.id

    {:ok, _settings} =
      Teams.put_settings(scope_for(c.bilal), team, %{
        "peer_tasks" => "hidden"
      })

    assert_push "team_settings_updated", %{team: ^team}

    # A refused change says nothing.
    {:error, _reason} =
      Teams.put_settings(scope_for(c.muaz), team, %{
        "peer_tasks" => "edit"
      })

    refute_push "team_settings_updated", _payload
  end

  test "hears a lead made, moved and updated on the team, after commit; a refused verb says nothing",
       c do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(c.muaz), Api.TeamChannel, "team:" <> c.backend.id)

    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend)

    {:ok, sheet} =
      Core.Leads.create(
        fiza,
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    id = sheet.id
    assert_push "lead_created", %{lead: ^id}

    from = %{"state" => "todo", "stage" => nil}
    {:ok, _} = LeadAct.run(fiza, :apply, id, %{"from" => from}, @now)
    assert_push "lead_moved", %{lead: ^id}

    {:ok, _} = Change.flag(fiza, :pin, id, @now)
    assert_push "lead_updated", %{lead: ^id}

    # A stale move and a duplicate save roll back and say nothing.
    {:error, {:lead_moved, _}} = LeadAct.run(fiza, :apply, id, %{"from" => from}, @now)
    refute_push "lead_moved", _payload

    {:error, {:duplicate_application, _}} =
      Core.Leads.create(
        fiza,
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    refute_push "lead_created", _payload
  end
end
