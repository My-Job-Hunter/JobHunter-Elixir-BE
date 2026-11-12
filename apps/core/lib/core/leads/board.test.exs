defmodule Core.Leads.BoardTest do
  @moduledoc """
  The leads board (AQ-04A §8.1, §8.3): one team's leads, collapsed and
  expanded, a retired stage's column, Done's thirty days and `older_done`,
  the `empty` answers, the filters, and what a member at `hidden` sees.
  """

  use Core.CoreCase, async: true

  alias Core.Leads.{Board, Pipelines}

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    :ok = Pipelines.ensure(scope_for(c.dawud), @now)
    c
  end

  defp board(scope, team, params \\ %{}),
    do: Board.show(scope, Map.put(params, "team_id", team.id), @now)

  defp column(board, key), do: Enum.find(board.columns, &(&1.key == key))
  defp ids(column), do: Enum.map(column.cards, & &1.id)

  test "team_id is required, another team is not found, view and pipeline are checked", c do
    assert Board.show(scope_for(c.fiza), %{}, @now) ==
             {:error, {:invalid, %{"team_id" => ["is required"]}}}

    assert board(scope_for(c.qasim), c.frontend) == {:error, :not_found}

    assert {:error, {:invalid, %{"view" => _}}} =
             board(scope_for(c.fiza), c.backend, %{"view" => "wide"})

    assert {:error, {:invalid, %{"pipeline" => _}}} =
             board(scope_for(c.fiza), c.backend, %{"view" => "expanded"})

    assert {:error, {:invalid, %{"quiet" => _}}} =
             board(scope_for(c.fiza), c.backend, %{"quiet" => "7"})

    assert {:error, {:invalid, %{"source" => _}}} =
             board(scope_for(c.fiza), c.backend, %{"source" => "myspace"})

    assert {:ok, %{empty: "team"}} = board(scope_for(c.dawud), c.backend)
  end

  test "collapsed: four columns; In progress by stage position, then activity; the card's shape",
       c do
    fiza = scope_for(c.fiza)
    todo = lead_fixture(fiza, profile: c.golang)
    late = lead_fixture(fiza, profile: c.golang, state: :in_progress, stage: "offer")
    early = lead_fixture(fiza, profile: c.golang, state: :in_progress, stage: "applied")
    held = lead_fixture(fiza, profile: c.golang, state: :on_hold, stage: "technical_1")
    done = lead_fixture(fiza, profile: c.golang, state: :done)

    {:ok, b} = board(fiza, c.backend)
    assert b.view == :collapsed and b.pipeline == nil and b.empty == nil
    assert Enum.map(b.columns, & &1.key) == ~w(todo in_progress on_hold done)
    assert ids(column(b, "todo")) == [todo.id]
    assert ids(column(b, "in_progress")) == [early.id, late.id]
    assert ids(column(b, "on_hold")) == [held.id]
    assert ids(column(b, "done")) == [done.id] and b.older_done == 0

    [card] = column(b, "on_hold").cards
    assert card.team == %{id: c.backend.id, name: "Backend squad"}
    assert card.stage.key == "technical_1" and card.progress == %{at: 5, of: 10}
    assert card.profile.title == "Golang backend" and card.customer.display_name == "Tanweer"
    assert card.owner.name == "Fiza" and card.resume_due == false
  end

  test "Done shows thirty days; the rest is counted", c do
    fiza = scope_for(c.fiza)
    recent = lead_fixture(fiza, profile: c.golang, state: :done)
    old = lead_fixture(fiza, profile: c.golang, state: :done)
    Repo.update!(Ecto.Changeset.change(old, finished_at: ~U[2026-09-01 09:00:00.000000Z]))

    {:ok, b} = board(fiza, c.backend)
    assert ids(column(b, "done")) == [recent.id] and b.older_done == 1
  end

  test "expanded: To do, every live stage, a retired stage still holding leads, On hold, Done",
       c do
    fiza = scope_for(c.fiza)

    on_assessment =
      lead_fixture(fiza, profile: c.golang, state: :in_progress, stage: "assessment")

    {:ok, live} = Pipelines.get(scope_for(c.hira), :employment)

    stages =
      live.stages
      |> Enum.reject(&(&1.key == "assessment"))
      |> Enum.map(&%{"key" => &1.key, "name" => &1.name, "kind" => to_string(&1.kind)})

    {:ok, _v2} = Pipelines.save(scope_for(c.hira), :employment, %{"stages" => stages}, @now)

    freelance =
      lead_fixture(fiza,
        profile: c.golang,
        pipeline: Pipelines.live(fiza, :freelance),
        state: :in_progress
      )

    {:ok, b} = board(fiza, c.backend, %{"view" => "expanded", "pipeline" => "employment"})
    assert b.pipeline.version == 2
    keys = Enum.map(b.columns, & &1.key)
    assert hd(keys) == "todo" and Enum.take(keys, -2) == ["on_hold", "done"]
    assert length(keys) == 1 + 9 + 1 + 2
    retired = column(b, "assessment")
    assert retired.stage.retired and ids(retired) == [on_assessment.id]
    refute freelance.id in Enum.flat_map(b.columns, &ids/1)

    {:ok, f} = board(fiza, c.backend, %{"view" => "expanded", "pipeline" => "freelance"})
    assert ids(column(f, "proposal_sent")) == [freelance.id]
  end

  test "filters: mine, customer, profile, stage, source, q, quiet, archived", c do
    fiza = scope_for(c.fiza)
    mine = lead_fixture(fiza, profile: c.golang, state: :in_progress, stage: "offer")
    qasims = lead_fixture(scope_for(c.qasim), profile: profile_fixture(c.naveed), state: :todo)
    archived = lead_fixture(fiza, profile: c.golang, archived: true)
    Repo.update!(Ecto.Changeset.change(qasims, last_activity_at: ~U[2026-09-01 09:00:00.000000Z]))

    all = fn params ->
      {:ok, b} = board(fiza, c.backend, params)
      Enum.flat_map(b.columns, &ids/1)
    end

    assert Enum.sort(all.(%{})) == Enum.sort([mine.id, qasims.id])
    assert all.(%{"owner" => "me"}) == [mine.id]
    assert all.(%{"customer" => c.naveed.id}) == [qasims.id]
    assert all.(%{"profile" => c.golang.id}) == [mine.id]
    assert all.(%{"stage" => "offer"}) == [mine.id]
    assert all.(%{"source" => "company_site"}) |> length() == 2
    assert all.(%{"source" => "upwork"}) == []
    assert all.(%{"quiet" => "30"}) == [qasims.id]
    assert all.(%{"archived" => "true"}) == [archived.id]
    assert all.(%{"q" => "no such title"}) == []

    {:ok, b} = board(scope_for(c.muaz), c.backend, %{"owner" => "me"})
    assert b.empty == "mine"
    {:ok, b} = board(fiza, c.backend, %{"q" => "zzz"})
    assert b.empty == nil
  end

  test "a member at hidden sees only their own; with nothing of their own, team_hidden", c do
    _fizas = lead_fixture(scope_for(c.fiza), profile: c.golang)
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})

    {:ok, b} = board(scope_for(c.muaz), c.backend)
    assert Enum.all?(b.columns, &(&1.cards == [])) and b.empty == "team_hidden"

    own = lead_fixture(scope_for(c.muaz), profile: profile_fixture(c.naveed))
    {:ok, b} = board(scope_for(c.muaz), c.backend)
    assert Enum.flat_map(b.columns, &ids/1) == [own.id] and b.empty == nil

    {:ok, b} = board(scope_for(c.bilal), c.backend)
    assert length(Enum.flat_map(b.columns, &ids/1)) == 2
  end

  describe "AQ-04B" do
    test "older=true opens Done's older leads too", c do
      fiza = scope_for(c.fiza)
      recent = lead_fixture(fiza, profile: c.golang, state: :done)
      old = lead_fixture(fiza, profile: c.golang, state: :done)
      Repo.update!(Ecto.Changeset.change(old, finished_at: ~U[2026-09-01 09:00:00.000000Z]))

      {:ok, b} = board(fiza, c.backend, %{"older" => "true"})
      assert ids(column(b, "done")) == [recent.id, old.id] and b.older_done == 0
    end

    test "lanes by profile, then by owner: rows of the same columns with their counts", c do
      fiza = scope_for(c.fiza)
      naveed = profile_fixture(c.naveed, title: "Golang")
      a = lead_fixture(fiza, profile: c.golang, as: :apply)
      b = lead_fixture(fiza, profile: naveed)
      d = lead_fixture(scope_for(c.qasim), profile: c.golang)

      {:ok, board} = board(fiza, c.backend, %{"lane" => "profile"})
      assert board.lane == :profile

      assert Enum.map(board.lanes, &{&1.name, &1.count}) == [
               {"Naveed · Golang", 1},
               {"Tanweer · Golang backend", 2}
             ]

      [_naveed, tanweer] = board.lanes
      assert ids(column(tanweer, "in_progress")) == [a.id]
      assert ids(column(tanweer, "todo")) == [d.id]

      {:ok, by_owner} = board(fiza, c.backend, %{"lane" => "owner"})
      assert Enum.map(by_owner.lanes, &{&1.name, &1.count}) == [{"Fiza", 2}, {"Qasim", 1}]
      assert Enum.sort(Enum.flat_map(by_owner.columns, &ids/1)) == Enum.sort([a.id, b.id, d.id])

      {:ok, none} = board(fiza, c.backend)
      assert none.lanes == nil and none.lane == :none
      assert {:error, {:invalid, %{"lane" => _}}} = board(fiza, c.backend, %{"lane" => "team"})
    end

    test "the label filter, and the card's next, follow_up, quiet and labels", c do
      fiza = scope_for(c.fiza)
      labelled = lead_fixture(fiza, profile: c.golang, as: :apply)
      _other = lead_fixture(fiza, profile: c.golang)
      label = label_fixture(fiza, c.backend, name: "Referral")
      Data.Labels.put_for_lead(labelled.id, [label.id])

      {:ok, b} = board(fiza, c.backend, %{"label" => label.id})
      assert [card] = Enum.flat_map(b.columns, & &1.cards)
      assert card.id == labelled.id
      assert card.labels == [%{id: label.id, name: "Referral"}]
      assert card.follow_up == %{state: :none, count: 0, of: 2}
      assert card.next == nil
      assert %{archives_on: %Date{}, warn: false} = card.quiet
    end
  end
end
