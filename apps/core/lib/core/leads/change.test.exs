defmodule Core.Leads.ChangeTest do
  @moduledoc """
  The verbs that keep, hand on or edit a lead (AQ-04A §7): archive and
  unarchive (the job unarchived too), pin and unpin (audited, no event),
  assign (someone in the team, the new owner told), CV (a document of the
  profile), pipeline (the stage mapped by kind) and edit (facts, audited).
  """

  use Core.CoreCase, async: true

  require Ecto.Query

  alias Core.Leads
  alias Core.Leads.{Act, Change, Pipelines}
  alias Data.Audit
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    job = job_fixture(scope_for(c.fiza), team: c.backend, title: "Backend Developer")

    {:ok, sheet} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "apply"},
        @now
      )

    c |> Map.put(:job, job) |> Map.put(:sheet, sheet)
  end

  defp kinds(id), do: id |> Store.events() |> Enum.map(& &1.kind)

  test "archive keeps the state; unarchive returns it and unarchives the job", c do
    fiza = scope_for(c.fiza)
    {:ok, _job} = Data.Jobs.archive(c.job, @now, c.fiza.id)

    {:ok, archived} = Change.flag(fiza, :archive, c.sheet.id, @now)
    assert archived.archived_at && archived.state == :in_progress
    assert Store.get(c.org.id, c.sheet.id).archive_reason == :by_hand
    assert {:ok, again} = Change.flag(fiza, :archive, c.sheet.id, ~U[2026-11-12 09:00:00Z])
    assert again.archived_at == archived.archived_at

    {:ok, back} = Change.flag(fiza, :unarchive, c.sheet.id, @now)
    assert back.archived_at == nil and back.state == :in_progress
    assert Data.Jobs.get(c.org.id, c.job.id).archived_at == nil

    assert Enum.any?(
             Audit.list_for_subject(c.org.id, "jobs", c.job.id),
             &(&1.action == "unarchived")
           )

    assert [:unarchived, :archived | _] = kinds(c.sheet.id)
  end

  test "archive and pin are the owner's or a lead's; a member at edit is refused in words", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})
    words = "Only the lead's owner, or a team lead, can archive or pin it."

    assert Change.flag(scope_for(c.qasim), :archive, c.sheet.id, @now) ==
             {:error, {:forbidden, words}}

    assert Change.flag(scope_for(c.qasim), :pin, c.sheet.id, @now) ==
             {:error, {:forbidden, words}}

    assert {:ok, %{is_pinned: true}} = Change.flag(scope_for(c.bilal), :pin, c.sheet.id, @now)
  end

  test "pin and unpin are audited, with no event and no activity", c do
    before = Store.get(c.org.id, c.sheet.id).last_activity_at
    {:ok, pinned} = Change.flag(scope_for(c.fiza), :pin, c.sheet.id, ~U[2026-11-12 09:00:00Z])
    assert pinned.is_pinned
    {:ok, unpinned} = Change.flag(scope_for(c.fiza), :unpin, c.sheet.id, @now)
    refute unpinned.is_pinned
    assert kinds(c.sheet.id) == [:applied]
    assert Store.get(c.org.id, c.sheet.id).last_activity_at == before
    actions = Audit.list_for_subject(c.org.id, "leads", c.sheet.id) |> Enum.map(& &1.action)
    assert "pinned" in actions and "unpinned" in actions
  end

  test "assign: to someone in the team, both names frozen, the new owner told", c do
    assert {:error, {:missing, [:owner_user_id]}} =
             Change.assign(scope_for(c.fiza), c.sheet.id, %{}, @now)

    assert {:error, {:invalid, %{"owner_user_id" => _}}} =
             Change.assign(
               scope_for(c.fiza),
               c.sheet.id,
               %{"owner_user_id" => user_fixture().id},
               @now
             )

    {:ok, handed} =
      Change.assign(scope_for(c.fiza), c.sheet.id, %{"owner_user_id" => c.qasim.id}, @now)

    assert handed.owner.user_id == c.qasim.id

    assert [
             %{kind: :owner_changed, from_label: "Fiza", to_label: "Qasim", visibility: :staff}
             | _
           ] = Store.events(c.sheet.id)

    assert [%{notification_kind_key: "leads.assigned"}] =
             Repo.all(Ecto.Query.where(Data.Notifications.Notification, user_id: ^c.qasim.id))

    # A member who is not the owner, even at edit, does not hand it on.
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :edit})

    assert Change.assign(scope_for(c.muaz), c.sheet.id, %{"owner_user_id" => c.muaz.id}, @now) ==
             {:error, {:forbidden, "Only the owner or a team lead can hand this lead on."}}
  end

  test "cv: a document of the lead's profile, written as cv_set", c do
    doc = document_fixture(c.golang, kind: :cv, label: "Golang CV")
    other = document_fixture(profile_fixture(c.tanweer, title: "Other"))
    {:ok, set} = Change.cv(scope_for(c.fiza), c.sheet.id, %{"document_id" => doc.id}, @now)
    assert set.cv.id == doc.id

    assert [%{kind: :cv_set, to_label: "Golang CV", document_id: doc_id} | _] =
             Store.events(c.sheet.id)

    assert doc_id == doc.id

    assert {:error, {:invalid, %{"document_id" => _}}} =
             Change.cv(scope_for(c.fiza), c.sheet.id, %{"document_id" => other.id}, @now)

    assert {:error, {:missing, [:document_id]}} =
             Change.cv(scope_for(c.fiza), c.sheet.id, %{}, @now)
  end

  test "pipeline: onto the other's live version, the stage mapped by kind, else to applied", c do
    fiza = scope_for(c.fiza)

    {:ok, t1} =
      Act.run(
        fiza,
        :move,
        c.sheet.id,
        %{
          "from" => %{"state" => "in_progress", "stage" => "applied"},
          "state" => "in_progress",
          "stage" => "technical_1"
        },
        @now
      )

    {:ok, moved} =
      Change.pipeline(
        fiza,
        t1.id,
        %{"from" => %{"state" => "in_progress", "stage" => "technical_1"}},
        @now
      )

    assert moved.pipeline.key == :freelance and moved.stage.key == "interview"

    assert [%{kind: :pipeline_changed, from_label: "Employment", to_label: "Freelance"} | _] =
             Store.events(c.sheet.id)

    {:ok, back} =
      Change.pipeline(
        fiza,
        moved.id,
        %{
          "from" => %{"state" => "in_progress", "stage" => "interview"},
          "pipeline_key" => "employment"
        },
        @now
      )

    assert back.stage.key == "technical_1"

    assert {:error, {:invalid, %{"pipeline_key" => _}}} =
             Change.pipeline(
               fiza,
               back.id,
               %{
                 "from" => %{"state" => "in_progress", "stage" => "technical_1"},
                 "pipeline_key" => "employment"
               },
               @now
             )

    assert {:error, {:lead_moved, _}} =
             Change.pipeline(fiza, back.id, %{"from" => %{"state" => "todo"}}, @now)

    # A stage with no kind in the other pipeline goes to its applied stage.
    {:ok, final} =
      Act.run(
        fiza,
        :move,
        back.id,
        %{
          "from" => %{"state" => "in_progress", "stage" => "technical_1"},
          "state" => "in_progress",
          "stage" => "final"
        },
        @now
      )

    {:ok, mapped} =
      Change.pipeline(
        fiza,
        final.id,
        %{"from" => %{"state" => "in_progress", "stage" => "final"}},
        @now
      )

    assert mapped.stage.key == "proposal_sent"

    assert Pipelines.live(fiza, :freelance).id ==
             Store.get(c.org.id, c.sheet.id).pipeline_version_id
  end

  test "edit: the facts, audited with what changed; no event", c do
    {:ok, edited} =
      Change.edit(
        scope_for(c.fiza),
        c.sheet.id,
        %{"priority" => "urgent", "cover_letter_md" => "Hello", "connects_spent" => 6},
        @now
      )

    assert edited.priority == :urgent and edited.cover_letter_md == "Hello" and
             edited.connects_spent == 6

    assert kinds(c.sheet.id) == [:applied]

    assert [%{before: %{"priority" => nil}, after: %{"priority" => "urgent"}} | _] =
             Audit.list_for_subject(c.org.id, "leads", c.sheet.id)
             |> Enum.filter(&(&1.action == "updated"))

    assert {:error, {:invalid, %{"priority" => _}}} =
             Change.edit(scope_for(c.fiza), c.sheet.id, %{"priority" => "now"}, @now)

    {:ok, todo} =
      Leads.create(
        scope_for(c.fiza),
        %{
          "job_id" => job_fixture(scope_for(c.fiza), team: c.backend).id,
          "profile_id" => c.golang.id,
          "as" => "save"
        },
        @now
      )

    assert {:error, {:invalid, %{"applied_at" => _}}} =
             Change.edit(
               scope_for(c.fiza),
               todo.id,
               %{"applied_at" => "2026-11-10T09:00:00Z"},
               @now
             )
  end
end
