defmodule ApiClient.LeadControllerTest do
  @moduledoc """
  *My applications* over HTTP (AQ-04A §8.2): the list with `older_done`,
  the customer's sheet (another customer's lead is 404), *I applied*, and
  the suggestions.
  """

  use ApiClient.ClientCase, async: true

  alias Core.Leads.Notes

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")

    {:ok, sheet} =
      Core.Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    Map.put(c, :lead, sheet)
  end

  test "GET /leads and GET /leads/:id: the customer's view only; another customer's is 404", c do
    list = body(as_customer(c.tanweer, :get, "/v1/leads"))
    assert Map.keys(list) |> Enum.sort() == ~w(done in_progress older_done on_hold todo)
    assert [%{"id" => id, "job" => %{"title" => "Backend Developer"}}] = list["todo"]
    assert id == c.lead.id

    sheet = body(as_customer(c.tanweer, :get, "/v1/leads/#{id}"))

    refute Map.has_key?(sheet, "owner") or Map.has_key?(sheet, "team") or
             Map.has_key?(sheet, "priority")

    assert sheet["can"] == %{"applied" => true}
    assert [%{"kind" => "saved"}] = sheet["events"]

    assert as_customer(c.naveed, :get, "/v1/leads/#{id}").status == 404
    assert code(call(c.fiza, :get, "/v1/leads")) == "not_a_customer"
  end

  test "GET /leads/:id gains the tasks shown to the customer, never a staff-only one, nor a note (AQ-04B §8.2)",
       c do
    for {title, access} <- [{"Send the portfolio link", "shared"}, {"Internal", "none"}] do
      {:ok, _} =
        Core.Tasks.create(
          scope_for(c.fiza),
          %{
            "title" => title,
            "team_id" => c.backend.id,
            "lead_id" => c.lead.id,
            "customer_access" => access
          },
          @now
        )
    end

    {:ok, _} =
      Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "Ours alone"}, @now)

    sheet = body(as_customer(c.tanweer, :get, "/v1/leads/#{c.lead.id}"))
    assert [%{"title" => "Send the portfolio link"} = task] = sheet["tasks"]
    refute Map.has_key?(task, "team") or Map.has_key?(task, "priority")
    kinds = Enum.map(sheet["events"], & &1["kind"])
    assert "task_created" in kinds
    refute "note_added" in kinds
    assert Enum.count(kinds, &(&1 == "task_created")) == 1
  end

  test "POST /leads/:id/applied with {from: {state: todo, stage: null}}; once only", c do
    conn =
      as_customer(c.tanweer, :post, "/v1/leads/#{c.lead.id}/applied", %{
        from: %{state: "todo", stage: nil}
      })

    assert conn.status == 200
    assert body(conn)["state"] == "in_progress" and body(conn)["stage"]["key"] == "applied"

    again =
      as_customer(c.tanweer, :post, "/v1/leads/#{c.lead.id}/applied", %{
        from: %{state: "in_progress", stage: "applied"}
      })

    assert again.status == 403
    assert body(again)["error"]["message"] == "You can say you applied while it is still To do."
  end

  test "GET /suggestions is [] while the setting is off", c do
    assert body(as_customer(c.tanweer, :get, "/v1/suggestions")) == []
  end
end
