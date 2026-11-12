defmodule Core.Leads.PortalTest do
  @moduledoc """
  The portal's leads (AQ-04A §8.2, §8.4): *My applications* from every team
  without team names, the customer's sheet cut in the context — no owner as
  an account, no team, no priority or pin, no hold or apply-again reason,
  no staff-only event, staff by first name only when names are on — and
  *Suggested for you* behind its setting.
  """

  use Core.CoreCase, async: true

  alias Core.Leads
  alias Core.Leads.{Act, Change, Portal}
  alias Data.Customers.Profile

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    {:ok, _link} = Data.Customers.assign_team(c.tanweer, c.frontend.id, ~D[2026-11-10])
    go = skill_fixture(c.org, name: "Go")
    c |> Map.put(:go, go)
  end

  defp apply_for(scope, team, profile) do
    job = job_fixture(scope, team: team, title: "Backend Developer")

    {:ok, sheet} =
      Leads.create(
        scope,
        %{"job_id" => job.id, "profile_id" => profile.id, "as" => "apply"},
        @now
      )

    sheet
  end

  defp seen(s), do: %{"state" => to_string(s.state), "stage" => s.stage && s.stage.key}

  test "My applications: leads from both teams, by state, no team; archived left out; Done folds after 30 days",
       c do
    back = apply_for(scope_for(c.fiza), c.backend, c.golang)
    front = apply_for(scope_for(c.hira), c.frontend, c.golang)
    gone = apply_for(scope_for(c.fiza), c.backend, c.golang)
    {:ok, _} = Change.flag(scope_for(c.fiza), :archive, gone.id, @now)
    old = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, state: :done)
    Repo.update!(Ecto.Changeset.change(old, finished_at: ~U[2026-09-01 09:00:00.000000Z]))

    {:ok, list} = Portal.list(customer_scope_for(c.tanweer), @now)
    assert Enum.sort(Enum.map(list.in_progress, & &1.id)) == Enum.sort([back.id, front.id])
    assert list.done == [] and list.older_done == 1
    row = hd(list.in_progress)

    assert Map.keys(row) |> Enum.sort() ==
             ~w(applied_at finished_at id job last_activity_at outcome profile stage state)a

    refute Map.has_key?(row.job, :team)
    assert Portal.list(scope_for(c.fiza), @now) == {:error, :not_found}
  end

  test "the customer's sheet strips §8.4's staff-only items, with names on and off", c do
    fiza = scope_for(c.fiza)
    sheet = apply_for(fiza, c.backend, c.golang)
    {:ok, _} = Change.edit(fiza, sheet.id, %{"priority" => "urgent"}, @now)
    {:ok, _} = Change.flag(fiza, :pin, sheet.id, @now)

    {:ok, held} =
      Act.run(
        fiza,
        :hold,
        sheet.id,
        %{"from" => seen(sheet), "hold_reason" => "Secret reason"},
        @now
      )

    {:ok, _} = Change.assign(fiza, sheet.id, %{"owner_user_id" => c.qasim.id}, @now)

    {:ok, again} =
      Act.run(
        scope_for(c.qasim),
        :apply_again,
        sheet.id,
        %{"from" => seen(held), "reason" => "Staff only why"},
        @now
      )

    assert again.state == :in_progress

    {:ok, view} = Leads.get(customer_scope_for(c.tanweer), sheet.id, @now)

    for key <- [
          :owner,
          :team,
          :priority,
          :is_pinned,
          :hold_reason,
          :recent,
          :created_by,
          :applied_by,
          :pipeline
        ] do
      refute Map.has_key?(view, key), "#{key} reached the customer"
    end

    assert view.can == %{applied: false}
    assert is_binary(view.job.source_url) and Map.has_key?(view.job, :description_md)
    kinds = Enum.map(view.events, & &1.kind)
    refute :owner_changed in kinds
    assert :applied in kinds and :state_moved in kinds
    refute Enum.any?(view.events, &Map.has_key?(&1, :note))

    assert Enum.all?(
             view.events,
             &(&1.actor.person == nil or &1.actor.person.name in ["Fiza", "Qasim"])
           )

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_staff_names: false})
    {:ok, hidden} = Leads.get(customer_scope_for(c.tanweer), sheet.id, @now)
    assert Enum.all?(hidden.events, &(&1.actor.person.name == "The team"))
  end

  test "suggestions: [] until a serving team turns them on; then that team's jobs ≥ 70 with no lead for the profile",
       c do
    {:ok, golang} =
      c.golang
      |> Profile.facts_changeset(%{
        engagement_types: ["full_time"],
        workplace_types: ["remote"]
      })
      |> Repo.update()

    :ok = Data.Profiles.put_skills(golang, [%{skill_id: c.go.id, level: :expert, years: 5}])
    scope = customer_scope_for(c.tanweer)
    hira = scope_for(c.hira)

    good = fn title ->
      job_fixture(hira,
        team: c.backend,
        title: title,
        engagement: :full_time,
        workplace: :remote,
        remote_scope: :global,
        skills: [{c.go, true}]
      )
    end

    open = good.("Go engineer")
    applied = good.("Go applied")

    {:ok, _} =
      Leads.create(
        hira,
        %{"job_id" => applied.id, "profile_id" => golang.id, "as" => "save"},
        @now
      )

    assert Portal.suggestions(scope, @now) == {:ok, []}

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_job_suggestions: true})
    {:ok, list} = Portal.suggestions(scope, @now)
    ids = Enum.map(list, & &1.job.id)
    assert open.id in ids
    refute applied.id in ids
    assert Enum.all?(list, &(&1.score >= 70 and &1.profile.id == golang.id))
    refute Map.has_key?(hd(list).job, :team)

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_job_suggestions: false})
    assert Portal.suggestions(scope, @now) == {:ok, []}
  end
end
