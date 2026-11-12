defmodule ApiTeam.CompanyControllerTest do
  @moduledoc "The console's company routes (AQ-03 §7): the picker, the card, its edit — §7.1's shapes."

  use ApiTeam.TeamCase, async: true

  @company ~w(created_by domain hq_country id industry inserted_at linkedin_url name notes_md open_jobs size_band
              website_url)

  setup do: board_cast_fixture()

  test "POST, GET, PATCH a company; the picker answers {id, name, domain}", c do
    conn =
      call(c.fiza, :post, "/v1/companies", %{name: "Bamboo Invest", domain: "bambooinvest.co.uk"})

    assert conn.status == 201
    company = body(conn)
    assert company |> Map.keys() |> Enum.sort() == @company

    assert %{"name" => "Bamboo Invest", "open_jobs" => [], "created_by" => %{"name" => "Fiza"}} =
             company

    assert body(call(c.muaz, :get, "/v1/companies", %{q: "bamboo"})) ==
             [
               %{
                 "id" => company["id"],
                 "name" => "Bamboo Invest",
                 "domain" => "bambooinvest.co.uk"
               }
             ]

    linkedin = "https://www.linkedin.com/company/bamboo-invest"

    assert %{"linkedin_url" => ^linkedin} =
             body(
               call(c.qasim, :patch, "/v1/companies/#{company["id"]}", %{linkedin_url: linkedin})
             )

    assert body(call(c.qasim, :get, "/v1/companies/#{company["id"]}"))["linkedin_url"] == linkedin
  end

  test "a second company of the same name is a field error", c do
    _first = call(c.fiza, :post, "/v1/companies", %{name: "Bamboo Invest"})
    conn = call(c.hira, :post, "/v1/companies", %{name: "bamboo invest"})

    assert conn.status == 422
    assert body(conn)["error"]["details"] == %{"name" => ["is already a company"]}
  end
end
