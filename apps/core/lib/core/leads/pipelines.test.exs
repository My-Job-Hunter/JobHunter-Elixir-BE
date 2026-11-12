defmodule Core.Leads.PipelinesTest do
  @moduledoc """
  The pipelines (AQ-04A §9): the defaults of §9.1, `ensure` idempotent, the
  read of both, and a save as a new version under §9.2's rules — rename,
  a custom stage anchored after an engine stage, at most six, the engine's
  order, the `applied` stage kept, a key never reused — while an older lead
  keeps its version.
  """

  use Core.CoreCase, async: true

  alias Core.Leads
  alias Core.Leads.Pipelines

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    :ok = Pipelines.ensure(scope_for(c.dawud), @now)
    c
  end

  defp rows(pipeline),
    do:
      Enum.map(
        pipeline.stages,
        &%{"key" => &1.key, "name" => &1.name, "kind" => to_string(&1.kind)}
      )

  test "the defaults: Employment 10 stages, Freelance 8, each at version 1; ensure twice writes nothing more",
       c do
    :ok = Pipelines.ensure(scope_for(c.dawud), @now)
    assert {:ok, [employment, freelance]} = Pipelines.list(scope_for(c.muaz))
    assert {employment.key, employment.name, employment.version} == {:employment, "Employment", 1}
    assert length(employment.stages) == 10 and length(freelance.stages) == 8

    assert hd(employment.stages) == %{
             key: "recruiter_contact",
             name: "Recruiter contact",
             kind: :inbound,
             anchor_kind: nil,
             position: 1
           }

    assert List.last(freelance.stages).key == "contract_started"
    refute employment.can_edit
    assert {:ok, %{can_edit: true}} = Pipelines.get(scope_for(c.hira), "freelance")
    assert Pipelines.get(scope_for(c.muaz), "other") == {:error, :not_found}
    assert Pipelines.list(customer_scope_for(c.tanweer)) == {:error, :not_found}
  end

  test "a lead's live read ensures on first use in an organisation that never bootstrapped", _c do
    org = organisation_fixture()
    team = team_fixture(org)
    lead = member_fixture(team, :lead)
    assert {:ok, [%{version: 1}, %{version: 1}]} = Pipelines.list(scope_for(lead))
  end

  test "Hira renames Recruiter screen and adds Reference check after Final: version 2; an older lead stays on 1",
       c do
    job = job_fixture(scope_for(c.fiza), team: c.backend)

    {:ok, before} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    {:ok, live} = Pipelines.get(scope_for(c.hira), :employment)

    stages =
      live
      |> rows()
      |> Enum.map(fn r ->
        if r["key"] == "recruiter_screen", do: %{r | "name" => "Recruiter call"}, else: r
      end)
      |> Enum.flat_map(fn r ->
        if r["key"] == "final",
          do: [r, %{"name" => "Reference check", "kind" => "custom", "anchor_kind" => "final"}],
          else: [r]
      end)

    assert {:ok, saved} =
             Pipelines.save(scope_for(c.hira), "employment", %{"stages" => stages}, @now)

    assert saved.version == 2 and length(saved.stages) == 11
    assert Enum.find(saved.stages, &(&1.key == "recruiter_screen")).name == "Recruiter call"

    assert %{key: "reference_check", kind: :custom, anchor_kind: :final, position: 9} =
             Enum.at(saved.stages, 8)

    assert [%{action: "pipeline_saved"}] =
             Data.Audit.list(c.org.id, %{subject_kind: "pipeline_versions"}, 10) |> Enum.take(1)

    {:ok, older} = Leads.get(scope_for(c.fiza), before.id, @now)
    assert older.pipeline.version == 1

    job2 = job_fixture(scope_for(c.fiza), team: c.backend)

    {:ok, after_} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job2.id, "profile_id" => c.golang.id, "as" => "save"},
        @now
      )

    assert after_.pipeline.version == 2
  end

  test "a key is never reused: a removed stage's name added again gets a new key", c do
    {:ok, live} = Pipelines.get(scope_for(c.hira), :employment)
    without = live |> rows() |> Enum.reject(&(&1["key"] == "ai_interview"))
    {:ok, _v2} = Pipelines.save(scope_for(c.hira), :employment, %{"stages" => without}, @now)

    with_custom =
      without ++ [%{"name" => "AI interview", "kind" => "custom", "anchor_kind" => "negotiation"}]

    {:ok, v3} = Pipelines.save(scope_for(c.hira), :employment, %{"stages" => with_custom}, @now)
    assert List.last(v3.stages).key == "ai_interview_2"
  end

  test "the rules: only a team lead or the system admin; the applied stage, the order, the anchors, the cap, the kinds",
       c do
    {:ok, live} = Pipelines.get(scope_for(c.hira), :employment)
    stages = rows(live)
    save = &Pipelines.save(scope_for(c.dawud), :employment, %{"stages" => &1}, @now)

    assert Pipelines.save(scope_for(c.muaz), :employment, %{"stages" => stages}, @now) ==
             {:error, {:forbidden, "Only a team lead can change a pipeline."}}

    assert {:error, {:invalid, %{"stages" => ["must keep the pipeline's applied stage"]}}} =
             save.(Enum.reject(stages, &(&1["key"] == "applied")))

    assert {:error, {:invalid, %{"stages" => ["must keep the engine stages in their order"]}}} =
             save.(Enum.reverse(stages))

    custom = %{"name" => "Portfolio review", "kind" => "custom", "anchor_kind" => "offer"}

    assert {:error,
            {:invalid, %{"stages" => ["must keep each custom stage after the stage it follows"]}}} =
             save.([custom | stages])

    seven =
      for n <- 1..7,
          do: %{"name" => "Extra #{n}", "kind" => "custom", "anchor_kind" => "negotiation"}

    assert {:error, {:invalid, %{"stages" => ["can hold at most 6 custom stages"]}}} =
             save.(stages ++ seven)

    assert {:error, {:invalid, %{"stages.0.kind" => _}}} =
             save.([%{hd(stages) | "kind" => "applied"} | tl(stages)])

    assert {:error, {:invalid, %{"stages.10.kind" => _}}} =
             save.(stages ++ [%{"name" => "New engine", "kind" => "offer"}])

    assert {:error, {:invalid, %{"stages.0.name" => _}}} =
             save.([%{hd(stages) | "name" => " "} | tl(stages)])

    assert {:error, {:invalid, %{"stages.0.key" => _}}} =
             save.([%{hd(stages) | "key" => "nope"} | tl(stages)])

    assert {:error, {:invalid, %{"stages" => _}}} = save.([])

    assert {:error, {:invalid, %{"stages" => _}}} =
             save.(
               stages ++
                 [%{"name" => "Offer", "kind" => "custom", "anchor_kind" => "negotiation"}]
             )

    # A removed stage is allowed, reorder within the engine's order too.
    {:ok, v2} = save.(Enum.reject(stages, &(&1["key"] == "assessment")))
    assert v2.version == 2 and length(v2.stages) == 9
  end

  test "fresh_key slugs a name and steps past used keys" do
    assert Pipelines.fresh_key("Reference check", MapSet.new()) == "reference_check"

    assert Pipelines.fresh_key("Reference check", MapSet.new(["reference_check"])) ==
             "reference_check_2"

    assert Pipelines.fresh_key("1st call!", MapSet.new()) == "stage_1st_call"
  end
end
