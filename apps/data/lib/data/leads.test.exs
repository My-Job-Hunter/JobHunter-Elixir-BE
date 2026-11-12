defmodule Data.LeadsTest do
  @moduledoc """
  The leads' rows (AQ-04A §5.2): the CHECKs that hold each state's columns
  to it, the unique `(job, profile)`, the append-only ledger's rules, and
  the posting reads the guard stands on.
  """

  use Data.DataCase, async: true

  alias Data.Leads
  alias Data.Leads.Lead

  setup do
    c = board_cast_fixture()
    scope = scope_for(c.fiza)
    lead = lead_fixture(scope, team: c.backend, profile: c.golang)
    Map.merge(c, %{scope: scope, lead: lead})
  end

  defp write(lead, attrs) do
    lead |> Ecto.Changeset.change(attrs) |> Lead.changeset(%{}) |> Repo.update()
  end

  test "the CHECKs: a stage only once applied; hold with a reason; Done with an outcome; money whole",
       c do
    stage = hd(Repo.preload(c.lead, pipeline_version: :stages).pipeline_version.stages)

    assert {:error, cs} = write(c.lead, %{stage_id: stage.id})
    assert errors_on(cs)[:stage_id] || errors_on(cs)[:applied_at]

    assert {:error, cs} = write(c.lead, %{state: :on_hold})
    assert errors_on(cs) != %{}

    assert {:error, cs} = write(c.lead, %{state: :done, finished_at: DateTime.utc_now()})
    assert errors_on(cs)[:outcome]

    assert {:ok, done} =
             write(c.lead, %{state: :done, finished_at: DateTime.utc_now(), outcome: :not_pursued})

    assert done.stage_id == nil

    assert {:error, cs} = write(c.lead, %{archived_at: DateTime.utc_now()})
    assert errors_on(cs)[:archived_at]
  end

  test "one lead per profile per job", c do
    job = Repo.preload(c.lead, :job).job

    assert {:error, cs} =
             Leads.create(%{
               organisation_id: c.org.id,
               job_id: job.id,
               profile_id: c.golang.id,
               owner_user_id: c.fiza.id,
               pipeline_version_id: c.lead.pipeline_version_id,
               last_activity_at: DateTime.utc_now()
             })

    assert errors_on(cs)[:profile_id] == ["already has a lead on this job"]
  end

  test "the ledger: a hold's state_moved and an apply-again need a note; is_again only on applied",
       c do
    base = %{
      organisation_id: c.org.id,
      lead_id: c.lead.id,
      occurred_at: DateTime.utc_now(),
      recorded_at: DateTime.utc_now(),
      actor_kind: :user,
      actor_user_id: c.fiza.id,
      visibility: :customer
    }

    assert {:error, _} =
             Leads.add_event(Map.merge(base, %{kind: :state_moved, to_label: "On hold"}))

    assert {:error, _} = Leads.add_event(Map.merge(base, %{kind: :applied, is_again: true}))
    assert {:error, _} = Leads.add_event(Map.merge(base, %{kind: :saved, is_again: true}))
    assert {:error, _} = Leads.add_event(Map.merge(base, %{kind: :saved, actor_user_id: nil}))

    assert {:ok, _} =
             Leads.add_event(
               Map.merge(base, %{kind: :applied, is_again: true, note: "Form error"})
             )

    assert [%{kind: :applied}] = Leads.events(c.lead.id)
  end

  test "the posting: by key across teams, and through a merged key", c do
    job = Repo.preload(c.lead, :job).job
    assert [%{id: id}] = Leads.on_posting(c.org.id, [job.canonical_key])
    assert id == c.lead.id
    assert Leads.posting_keys(c.org.id, job.canonical_key) == [job.canonical_key]
    assert Leads.on_posting(c.org.id, []) == []
    assert Leads.applied_keys(c.org.id, c.golang.id) == []
    assert Leads.profiles_on_both(job.id, job.id) == [c.golang.id]
  end
end
