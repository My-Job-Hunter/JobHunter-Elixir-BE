defmodule Core.Retention.ApprovalsTest do
  @moduledoc """
  AQ-07 §10 (QP7-22): a purged lead takes its approvals — versions, slots,
  decisions, comments and their notifications — and their files, rows
  then bytes; a file another approval still holds stays; a profile's
  approvals stay with the profile.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Approvals
  alias Core.Approvals.{Act, Comments}
  alias Core.Retention

  @t0 ~U[2026-11-01 09:00:00.000000Z]

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend, title: "Platform Engineer")

    Repo.update_all(from(j in Data.Jobs.Job, where: j.id == ^job.id),
      set: [last_activity_at: @t0, first_seen_at: @t0]
    )

    quiet = lead_fixture(fiza, job: job, profile: c.golang, as: :apply, last_activity_at: @t0)
    %{leads: 1} = Retention.archive(day(90))

    {:ok, file} = Core.Media.store_attachment(fiza, "Case study\n", "case.txt", day(91))

    {:ok, a} =
      Approvals.draft(
        fiza,
        %{
          team_id: c.backend.id,
          lead_id: quiet.id,
          approval_kind: "asset",
          title: "Case study",
          media_ids: [file.id],
          slots: [%{slot: "customer"}],
          submit: true
        },
        day(91)
      )

    {:ok, _} =
      Act.decide(
        customer_scope_for(c.tanweer),
        a.id,
        %{decision: "approved", version: 1},
        day(91)
      )

    {:ok, _} = Comments.create(fiza, a.id, %{body_md: "Thanks"}, day(91))

    {:ok, pitch} =
      Approvals.draft(
        scope_for(c.muaz),
        %{
          team_id: c.backend.id,
          profile_id: c.golang.id,
          approval_kind: "profile_change",
          title: "Pitch",
          proposed: %{headline: "Go"},
          submit: true
        },
        day(91)
      )

    Map.merge(c, %{quiet: quiet, approval: a, media: file, pitch: pitch})
  end

  test "the purge takes the lead's approvals and their files; the profile's stays", c do
    assert {:ok, _bytes} = Core.Storage.fetch(c.media.storage_key)
    assert %{leads: 1} = Retention.purge(day(180))

    assert Repo.get(Data.Leads.Lead, c.quiet.id) == nil
    assert Repo.get(Data.Approvals.Approval, c.approval.id) == nil

    assert Repo.all(from(v in Data.Approvals.Version, where: v.approval_id == ^c.approval.id)) ==
             []

    assert Repo.all(from(d in Data.Approvals.Decision, where: d.approval_id == ^c.approval.id)) ==
             []

    assert Repo.all(from(x in Data.Approvals.Comment, where: x.approval_id == ^c.approval.id)) ==
             []

    assert Repo.all(from(r in Data.Approvals.Reviewer, where: r.approval_id == ^c.approval.id)) ==
             []

    assert Repo.all(
             from(n in Data.Notifications.Notification, where: n.approval_id == ^c.approval.id)
           ) ==
             []

    assert Repo.get(Data.Files.Media, c.media.id) == nil
    assert {:error, _gone} = Core.Storage.fetch(c.media.storage_key)

    assert %{state: :pending} = Data.Approvals.get_for_system(c.pitch.id)
    assert %{leads: 0} = Retention.purge(day(180))
  end
end
