defmodule ApiTeam.StageControllerTest do
  @moduledoc "A person's own stages (AQ-02 §7.2, §7.6): `{stages: [{id, name, position, in_use}], suggested}`."

  use ApiTeam.TeamCase, async: true

  test "the suggestions, add, rename, reorder, remove — each person their own" do
    org = organisation_fixture()
    team = team_fixture(org)
    fiza = member_fixture(team, :member)
    qasim = member_fixture(team, :member)

    assert body(call(fiza, :get, "/v1/me/stages")) == %{
             "stages" => [],
             "suggested" => [
               "Sourcing",
               "Preparing",
               "Waiting on the customer",
               "Waiting on the recruiter"
             ]
           }

    %{"stages" => [sourcing | _three], "suggested" => []} =
      body(call(fiza, :post, "/v1/me/stages", %{suggested: true}))

    assert %{"name" => "Sourcing", "position" => 0, "in_use" => 0} = sourcing
    assert call(fiza, :post, "/v1/me/stages", %{name: "SOURCING"}).status == 422

    %{"stages" => [renamed | _rest]} =
      body(call(fiza, :patch, "/v1/me/stages/#{sourcing["id"]}", %{name: "Hunting"}))

    assert renamed["name"] == "Hunting"
    assert call(qasim, :patch, "/v1/me/stages/#{sourcing["id"]}", %{name: "Mine"}).status == 404

    %{"stages" => stages} = body(call(fiza, :get, "/v1/me/stages"))
    ids = stages |> Enum.map(& &1["id"]) |> Enum.reverse()

    assert Enum.map(
             body(call(fiza, :put, "/v1/me/stages/order", %{ids: ids}))["stages"],
             & &1["id"]
           ) == ids

    assert length(body(call(fiza, :delete, "/v1/me/stages/#{sourcing["id"]}"))["stages"]) == 3
  end
end
