defmodule Core.CompaniesTest do
  @moduledoc """
  Companies (AQ-03 QP3-6): the picker by normalised name, the card with its
  open jobs, a second company of the same name refused, every write audited.
  """

  use Core.CoreCase, async: true

  alias Core.Companies
  alias Data.Audit

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    cast = board_cast_fixture()
    Map.put(cast, :fiza_scope, scope_for(cast.fiza))
  end

  test "create, then a second company with the same name, differently written, is refused", c do
    assert {:ok, company} =
             Companies.create(
               c.fiza_scope,
               %{"name" => "Bamboo Invest", "hq_country" => "gb", "size_band" => "51_200"},
               @now
             )

    assert %{
             name: "Bamboo Invest",
             hq_country: "GB",
             size_band: :"51_200",
             open_jobs: [],
             created_by: %{name: "Fiza"}
           } =
             company

    assert {:error, %Ecto.Changeset{} = changeset} =
             Companies.create(c.fiza_scope, %{"name" => " bamboo   INVEST"}, @now)

    assert errors_on(changeset).name == ["is already a company"]
    assert [%{action: "created"}] = Audit.list_for_subject(c.org.id, "companies", company.id)
  end

  test "the card lists the company's open, live jobs; an edit is audited with what changed", c do
    bamboo = company_fixture(c.org, name: "Bamboo Invest")
    open = job_fixture(c.fiza_scope, company: bamboo, title: "Backend Developer")
    _closed = job_fixture(c.fiza_scope, company: bamboo, status: :closed)
    _archived = job_fixture(c.fiza_scope, company: bamboo, archived: true)

    assert {:ok, %{open_jobs: [%{id: id, title: "Backend Developer"}]}} =
             Companies.get(c.fiza_scope, bamboo.id)

    assert id == open.id

    linkedin = "https://www.linkedin.com/company/bamboo-invest"

    assert {:ok, %{linkedin_url: ^linkedin}} =
             Companies.update(scope_for(c.qasim), bamboo.id, %{"linkedin_url" => linkedin}, @now)

    assert [
             %{
               action: "updated",
               before: %{"linkedin_url" => nil},
               after: %{"linkedin_url" => ^linkedin}
             }
           ] =
             Audit.list_for_subject(c.org.id, "companies", bamboo.id)
  end

  test "the picker: at most 20 by name, by prefix, substring or trigram, accent-blind", c do
    for name <- ["Bamboo Invest", "Bambú Labs", "TuxCare", "Fennec Cloud"],
        do: company_fixture(c.org, name: name)

    names = fn q -> c.fiza_scope |> Companies.search(q) |> elem(1) |> Enum.map(& &1.name) end

    assert names.("bamb") == ["Bamboo Invest", "Bambú Labs"]
    assert names.("BAMBU") == ["Bambú Labs"]
    assert names.("care") == ["TuxCare"]
    assert names.("Fenec Cloud") == ["Fennec Cloud"]
    assert length(names.(nil)) == 4
  end

  test "a domain is one company's, written any way", c do
    {:ok, _one} =
      Companies.create(
        c.fiza_scope,
        %{"name" => "Acme", "domain" => "https://www.Acme.io/careers"},
        @now
      )

    assert {:error, changeset} =
             Companies.create(c.fiza_scope, %{"name" => "Acme Two", "domain" => "acme.io"}, @now)

    assert errors_on(changeset).domain == ["is already a company's"]
  end
end
