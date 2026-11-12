defmodule Core.Leads.LabelsTest do
  @moduledoc """
  AQ-04B §4, §9, QP4b-17, and the labels and saved-views matrix beside
  `Core.LeadAccessMatrixTest`: a team lead or the system admin makes,
  renames and removes a team's labels ("Only a team lead can change the
  team's labels."); anyone in the team reads them; another team finds
  nothing. Labelling a lead is whoever may change it, with labels of the
  lead's team only, and writes `labelled`.
  """

  use Core.CoreCase, async: true

  alias Core.Leads.Labels
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]
  @words "Only a team lead can change the team's labels."

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang)
    Map.merge(c, %{lead: lead, farah: farah})
  end

  defp make(who, team, name),
    do: Labels.create(who, %{"team_id" => team.id, "name" => name}, @now)

  test "the matrix: make, rename, remove by chair", c do
    assert {:ok, %{name: "Priority client", lead_count: 0} = label} =
             make(scope_for(c.hira), c.backend, "Priority client")

    assert {:ok, _} = make(scope_for(c.bilal), c.backend, "Referral")
    assert {:ok, _} = make(scope_for(c.dawud), c.backend, "Dawud's")
    assert make(scope_for(c.muaz), c.backend, "Mine") == {:error, {:forbidden, @words}}
    assert make(scope_for(c.farah), c.backend, "Theirs") == {:error, :not_found}
    assert make(customer_scope_for(c.tanweer), c.backend, "X") == {:error, :not_found}

    assert Labels.rename(scope_for(c.muaz), label.id, %{"name" => "P"}, @now) ==
             {:error, {:forbidden, @words}}

    assert {:ok, %{name: "Priority"}} =
             Labels.rename(scope_for(c.bilal), label.id, %{"name" => "Priority"}, @now)

    assert Labels.delete(scope_for(c.fiza), label.id, @now) == {:error, {:forbidden, @words}}
    assert Labels.delete(scope_for(c.farah), label.id, @now) == {:error, :not_found}
    assert Labels.delete(scope_for(c.hira), label.id, @now) == :ok

    assert {:ok, names} = Labels.list(scope_for(c.muaz), %{"team_id" => c.backend.id})
    assert Enum.map(names, & &1.name) == ["Dawud's", "Referral"]
    assert Labels.list(scope_for(c.farah), %{"team_id" => c.backend.id}) == {:error, :not_found}
  end

  test "a name is unique in its team, whatever the case; another team may reuse it", c do
    {:ok, _} = make(scope_for(c.hira), c.backend, "Referral")

    assert {:error, %Ecto.Changeset{errors: [name: {"is already a label of this team", _}]}} =
             make(scope_for(c.hira), c.backend, "  referral ")

    assert {:ok, _} = make(scope_for(c.hira), c.frontend, "Referral")
  end

  test "labelling a lead: replaces the set, writes labelled once, counts on the label", c do
    {:ok, a} = make(scope_for(c.hira), c.backend, "Priority client")
    {:ok, b} = make(scope_for(c.hira), c.backend, "Referral")

    assert {:ok, %{labels: [%{name: "Priority client"}, %{name: "Referral"}]}} =
             Labels.put_on_lead(
               scope_for(c.fiza),
               c.lead.id,
               %{"label_ids" => [a.id, b.id]},
               @now
             )

    assert {:ok, _} =
             Labels.put_on_lead(
               scope_for(c.fiza),
               c.lead.id,
               %{"label_ids" => [b.id, a.id]},
               @now
             )

    assert [%{kind: :labelled, to_label: "Priority client, Referral", visibility: :staff}] =
             Store.events(c.lead.id)

    {:ok, _} = Labels.put_on_lead(scope_for(c.fiza), c.lead.id, %{"label_ids" => [b.id]}, @now)
    [latest | _] = Store.events(c.lead.id)
    assert latest.from_label == "Priority client, Referral" and latest.to_label == "Referral"

    {:ok, list} = Labels.list(scope_for(c.fiza), %{"team_id" => c.backend.id})
    assert Enum.map(list, &{&1.name, &1.lead_count}) == [{"Priority client", 0}, {"Referral", 1}]
  end

  test "only the lead's team's labels; a viewer is refused in words", c do
    {:ok, theirs} = make(scope_for(c.hira), c.frontend, "Frontend's")

    assert Labels.put_on_lead(scope_for(c.fiza), c.lead.id, %{"label_ids" => [theirs.id]}, @now) ==
             {:error, {:invalid, %{"label_ids" => ["has a label that is not this team's"]}}}

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})

    assert Labels.put_on_lead(scope_for(c.muaz), c.lead.id, %{"label_ids" => []}, @now) ==
             {:error,
              {:forbidden, "You can see this, but only its owner or a team lead can change it."}}
  end
end
