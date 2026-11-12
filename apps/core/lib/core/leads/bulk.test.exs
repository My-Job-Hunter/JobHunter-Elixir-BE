defmodule Core.Leads.BulkTest do
  @moduledoc """
  AQ-04B §8.1, QP4b-19: bulk assign, move, label, archive and unarchive —
  each lead its own verb and transaction; what was done and what was
  refused, with the verb's own reason (a lead that moved meanwhile, a lead
  the caller may not change, one they cannot see).
  """

  use Core.CoreCase, async: true

  alias Core.Leads.{Act, Bulk, Change}
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    leads = for _ <- 1..3, do: lead_fixture(fiza, team: c.backend, as: :apply)
    Map.put(c, :leads, leads)
  end

  defp seen(lead), do: %{"id" => lead.id, "state" => "in_progress", "stage" => "applied"}

  test "assign three to Qasim, one moved meanwhile: two done, one refused lead_moved", c do
    [a, b, moved] = c.leads

    {:ok, _} =
      Act.run(
        scope_for(c.fiza),
        :move,
        moved.id,
        %{
          "from" => %{"state" => "in_progress", "stage" => "applied"},
          "state" => "in_progress",
          "stage" => "recruiter_screen"
        },
        @now
      )

    assert {:ok, %{done: done, refused: [%{id: id, reason: {:lead_moved, _}}]}} =
             Bulk.run(
               scope_for(c.fiza),
               %{
                 "action" => "assign",
                 "lead_ids" => Enum.map(c.leads, & &1.id),
                 "owner_user_id" => c.qasim.id,
                 "seen" => Enum.map(c.leads, &seen/1)
               },
               @now
             )

    assert Enum.sort(done) == Enum.sort([a.id, b.id]) and id == moved.id
    assert Store.reload(a).owner_user_id == c.qasim.id
    assert Store.reload(moved).owner_user_id == c.fiza.id
  end

  test "move to Done with an outcome; a refusal per lead in its verb's words", c do
    [a, b, c3] = c.leads
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :view})
    {:ok, _} = Change.flag(scope_for(c.fiza), :archive, c3.id, @now)

    assert {:ok, %{done: [], refused: refused}} =
             Bulk.run(
               scope_for(c.muaz),
               %{
                 "action" => "move",
                 "lead_ids" => [a.id],
                 "state" => "done",
                 "outcome" => "rejected"
               },
               @now
             )

    assert [
             %{
               reason:
                 {:forbidden,
                  "You can see this, but only its owner or a team lead can change it."}
             }
           ] = refused

    assert {:ok,
            %{
              done: [id],
              refused: [%{id: archived, reason: {:invalid, _}}, %{reason: :not_found}]
            }} =
             Bulk.run(
               scope_for(c.fiza),
               %{
                 "action" => "move",
                 "lead_ids" => [b.id, c3.id, Ecto.UUID.generate()],
                 "state" => "done",
                 "outcome" => "rejected"
               },
               @now
             )

    assert id == b.id and archived == c3.id
    assert Store.reload(b).outcome == :rejected
  end

  test "label adds to each lead's own; archive and unarchive", c do
    [a, b, _] = c.leads
    one = label_fixture(scope_for(c.hira), c.backend, name: "Referral")
    two = label_fixture(scope_for(c.hira), c.backend, name: "Priority client")
    Data.Labels.put_for_lead(a.id, [one.id])

    assert {:ok, %{done: [_, _], refused: []}} =
             Bulk.run(
               scope_for(c.fiza),
               %{"action" => "label", "lead_ids" => [a.id, b.id], "label_ids" => [two.id]},
               @now
             )

    labels = Data.Labels.for_leads([a.id, b.id])
    assert Enum.map(labels[a.id], & &1.name) == ["Priority client", "Referral"]
    assert Enum.map(labels[b.id], & &1.name) == ["Priority client"]

    assert {:ok, %{done: [_, _]}} =
             Bulk.run(
               scope_for(c.fiza),
               %{"action" => "archive", "lead_ids" => [a.id, b.id]},
               @now
             )

    refute is_nil(Store.reload(a).archived_at)

    assert {:ok, %{done: [_]}} =
             Bulk.run(scope_for(c.fiza), %{"action" => "unarchive", "lead_ids" => [a.id]}, @now)

    assert is_nil(Store.reload(a).archived_at)
  end

  test "the body: Nothing selected, an unknown action, a missing field", c do
    fiza = scope_for(c.fiza)

    assert Bulk.run(fiza, %{"action" => "archive", "lead_ids" => []}, @now) ==
             {:error, {:invalid, %{"lead_ids" => ["Nothing selected."]}}}

    assert {:error, {:invalid, %{"action" => _}}} =
             Bulk.run(fiza, %{"action" => "delete", "lead_ids" => [hd(c.leads).id]}, @now)

    assert Bulk.run(fiza, %{"action" => "assign", "lead_ids" => [hd(c.leads).id]}, @now) ==
             {:error, {:missing, [:owner_user_id]}}
  end
end
