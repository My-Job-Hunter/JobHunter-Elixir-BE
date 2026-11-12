defmodule Core.SavedViewsTest do
  @moduledoc """
  AQ-04B §4, §9, QP4b-16: a saved view is its owner's alone (anyone else's
  is not found); it keeps the query **without the team**, so it works in
  every team; the Tracker's columns are checked against the vocabulary.
  """

  use Core.CoreCase, async: true

  alias Core.SavedViews

  setup do: board_cast_fixture()

  test "Fiza saves a Tracker view; the team is dropped from its query", c do
    fiza = scope_for(c.fiza)

    assert {:ok, view} =
             SavedViews.create(fiza, %{
               "screen" => "tracker",
               "name" => "Golang · in progress",
               "query" => "?team=#{c.backend.id}&state=in_progress&profile=#{c.golang.id}",
               "columns" => ["title", "company", "next"]
             })

    assert view.query == "profile=#{c.golang.id}&state=in_progress"
    assert view.columns == [:title, :company, :next] and view.position == 0

    assert {:ok, second} =
             SavedViews.create(fiza, %{
               "screen" => "tracker",
               "name" => "Mine",
               "query" => %{"owner" => "me", "team_id" => c.backend.id}
             })

    assert second.query == "owner=me" and second.position == 1
    assert {:ok, [_, _]} = SavedViews.list(fiza, %{"screen" => "tracker"})
    assert {:ok, []} = SavedViews.list(fiza, %{"screen" => "jobs"})
  end

  test "the matrix: the owner alone reads, renames and deletes", c do
    {:ok, view} =
      SavedViews.create(scope_for(c.fiza), %{"screen" => "leads", "name" => "Lanes by owner"})

    for who <- [c.hira, c.dawud, c.qasim] do
      assert SavedViews.update(scope_for(who), view.id, %{"name" => "X"}) == {:error, :not_found}
      assert SavedViews.delete(scope_for(who), view.id) == {:error, :not_found}
      assert {:ok, []} = SavedViews.list(scope_for(who), %{})
    end

    assert {:ok, %{name: "By owner", position: 3}} =
             SavedViews.update(scope_for(c.fiza), view.id, %{
               "name" => "By owner",
               "position" => 3
             })

    assert SavedViews.delete(scope_for(c.fiza), view.id) == :ok
  end

  test "field errors: a screen off the list, columns off the Tracker's, a name twice", c do
    fiza = scope_for(c.fiza)

    assert {:error, {:invalid, %{"screen" => _}}} =
             SavedViews.create(fiza, %{"screen" => "nope", "name" => "X"})

    assert {:error, {:invalid, %{"columns" => _}}} =
             SavedViews.create(fiza, %{"screen" => "tracker", "name" => "X", "columns" => ["x"]})

    assert {:error, {:invalid, %{"columns" => _}}} =
             SavedViews.create(fiza, %{"screen" => "jobs", "name" => "X", "columns" => ["title"]})

    {:ok, _} = SavedViews.create(fiza, %{"screen" => "board", "name" => "Mine"})

    assert {:error, %Ecto.Changeset{}} =
             SavedViews.create(fiza, %{"screen" => "board", "name" => "MINE"})
  end
end
