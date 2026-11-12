defmodule Data.TeamsTest do
  use Data.DataCase, async: true

  alias Data.Teams

  @now ~U[2026-11-09 10:00:00.000000Z]

  test "a team's slug follows its name and is unique within the organisation" do
    org = organisation_fixture()
    assert {:ok, team} = Teams.create(%{organisation_id: org.id, name: "Backend squad"})
    assert team.slug == "backend-squad"
    assert {:error, cs} = Teams.create(%{organisation_id: org.id, name: "Backend Squad"})
    assert errors_on(cs).organisation_id || errors_on(cs).slug

    assert {:ok, _other} =
             Teams.create(%{organisation_id: organisation_fixture().id, name: "Backend squad"})
  end

  test "list leaves out archived teams unless asked" do
    org = organisation_fixture()
    team = team_fixture(org)
    {:ok, _archived} = Teams.archive(team, @now)
    assert Teams.list(org.id) == []
    assert [%{id: id}] = Teams.list(org.id, include_archived: true)
    assert id == team.id
  end

  test "one open membership per person per team; a closed one does not block a new one" do
    org = organisation_fixture()
    team = team_fixture(org)
    user = member_fixture(team, :member)

    assert {:error, cs} =
             Teams.add_member(%{team_id: team.id, user_id: user.id, role: :lead, joined_at: @now})

    assert errors_on(cs).team_id
    {:ok, _left} = Teams.leave(Teams.get_open_member(team.id, user.id), @now)

    assert {:ok, again} =
             Teams.add_member(%{team_id: team.id, user_id: user.id, role: :lead, joined_at: @now})

    assert again.role == :lead
    assert length(Teams.list_members(team.id)) == 1
  end

  test "a role outside the vocabulary is refused" do
    org = organisation_fixture()
    team = team_fixture(org)

    assert {:error, cs} =
             Teams.add_member(%{
               team_id: team.id,
               user_id: user_fixture().id,
               role: :boss,
               joined_at: @now
             })

    assert errors_on(cs).role
  end

  test "settings: code defaults until written (QT-4: view · view · edit)" do
    org = organisation_fixture()
    team = team_fixture(org)
    defaults = Teams.get_settings(team.id)
    assert {defaults.peer_tasks, defaults.peer_leads, defaults.peer_jobs} == {:view, :view, :edit}

    assert {:ok, row} = Teams.put_settings(team.id, %{peer_tasks: "hidden"})
    assert row.peer_tasks == :hidden and row.peer_jobs == :edit and row.customer_sees_staff_names
  end

  test "settings: a level off the vocabulary is refused" do
    team = team_fixture(organisation_fixture())
    assert {:error, cs} = Teams.put_settings(team.id, %{peer_jobs: "sometimes"})
    assert errors_on(cs).peer_jobs
  end

  test "memberships_of and memberships_in carry the teams and people" do
    org = organisation_fixture()
    backend = team_fixture(org)
    frontend = team_fixture(org)
    user = member_fixture(backend, :lead)
    member_fixture(frontend, :member, user)

    assert Teams.memberships_of(user.id) |> Enum.map(& &1.team.id) |> Enum.sort() ==
             Enum.sort([backend.id, frontend.id])

    assert [m] = Teams.memberships_in([backend.id])
    assert m.user.person.display_name == "Test Person" and m.team.id == backend.id
    assert Teams.memberships_in([]) == []
  end
end
