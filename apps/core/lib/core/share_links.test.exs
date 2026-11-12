defmodule Core.ShareLinkTest do
  @moduledoc """
  Share links (AQ-03B §3.3, §5.1, §7): made by whoever sees the item, the
  token shown once and stored hashed; each level shows its fields and no
  more; a customer, another organisation, an expired or a revoked link is
  not found; an opening is audited once per person per link per day;
  revoking is the maker's, a lead's or an admin's.
  """

  use Core.CoreCase, async: true

  alias Core.Leads.Act
  alias Core.ShareLinks
  alias Data.Audit
  alias Data.Repo
  alias Data.ShareLinks.ShareLink

  @now ~U[2026-11-11 09:00:00.000000Z]

  @task_summary ~w(id title state stage priority due_at due_on customer assignees author
                   inserted_at)a
  @job_summary ~w(id title company source status workplace engagement money posted_on
                  first_seen_at created_by)a

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    fiza = scope_for(c.fiza)

    task =
      task_fixture(fiza,
        team: c.backend,
        customer: c.tanweer,
        primary: c.fiza,
        description: "Ten Go roles, remote."
      )

    job =
      job_fixture(fiza,
        team: c.backend,
        title: "Backend Developer",
        description_md: "Go and PostgreSQL."
      )

    Map.merge(c, %{farah: farah, fiza_scope: fiza, task: task, job: job})
  end

  defp make(scope, subject, params \\ %{"level" => "summary"}) do
    {:ok, %{link: link, path: "/s/" <> token}} = ShareLinks.create(scope, subject, params, @now)
    {link, token}
  end

  defp opened(c, link),
    do:
      c.org.id
      |> Audit.list_for_subject("share_links", link.id)
      |> Enum.filter(&(&1.action == "share_link_opened"))

  test "made by whoever sees the item: a 43-character token, only its SHA-256 kept, audited", c do
    {link, token} =
      make(c.fiza_scope, {:task, c.task.id}, %{"level" => "details", "expires_in_days" => 7})

    assert byte_size(token) == 43
    assert link.level == :details and link.expires_at == DateTime.add(@now, 7, :day)
    assert Repo.get!(ShareLink, link.id).token_sha256 == :crypto.hash(:sha256, token)

    assert [%{action: "share_link_created", after: %{"team_id" => team_id, "level" => "details"}}] =
             Audit.list_for_subject(c.org.id, "share_links", link.id)

    assert team_id == c.backend.id

    # Somebody who cannot see the item cannot share it, nor list its links.
    farah = scope_for(c.farah)

    assert ShareLinks.create(farah, {:task, c.task.id}, %{"level" => "summary"}, @now) ==
             {:error, :not_found}

    assert ShareLinks.list(farah, {:job, c.job.id}) == {:error, :not_found}

    assert {:error, {:invalid, %{"level" => _}}} =
             ShareLinks.create(c.fiza_scope, {:job, c.job.id}, %{"level" => "everything"}, @now)

    assert {:error, {:invalid, %{"expires_in_days" => _}}} =
             ShareLinks.create(
               c.fiza_scope,
               {:job, c.job.id},
               %{"level" => "summary", "expires_in_days" => 3},
               @now
             )

    assert {:ok, [%{id: id}]} = ShareLinks.list(scope_for(c.muaz), {:task, c.task.id})
    assert id == link.id
  end

  test "each level of a task shows its fields and no more", c do
    farah = scope_for(c.farah)

    {_link, summary} = make(c.fiza_scope, {:task, c.task.id})
    assert {:ok, shared} = ShareLinks.open(farah, summary, @now)

    assert %{
             subject: :task,
             level: :summary,
             team: %{name: "Backend squad"},
             shared_by: %{name: "Fiza"}
           } = shared

    assert Enum.sort(Map.keys(shared.item)) == Enum.sort(@task_summary)
    assert [%{name: "Fiza"}] = shared.item.assignees

    {_link, details} = make(c.fiza_scope, {:task, c.task.id}, %{"level" => "details"})
    assert {:ok, %{item: item}} = ShareLinks.open(farah, details, @now)
    assert item.description == "Ten Go roles, remote."
    refute Map.has_key?(item, :history)

    {:ok, _sheet} = Core.Tasks.update(c.fiza_scope, c.task.id, %{"priority" => "high"}, @now)

    {_link, history} = make(c.fiza_scope, {:task, c.task.id}, %{"level" => "details_history"})
    assert {:ok, %{item: item}} = ShareLinks.open(farah, history, @now)
    assert item.description == "Ten Go roles, remote."

    assert [%{actor: %{name: "Fiza"}, lines: [%{field: :priority, to_label: "High"}]}] =
             item.history
  end

  test "each level of a job shows its fields and no more", c do
    farah = scope_for(c.farah)

    {_link, summary} = make(c.fiza_scope, {:job, c.job.id})
    assert {:ok, %{subject: :job, item: item}} = ShareLinks.open(farah, summary, @now)
    assert Enum.sort(Map.keys(item)) == Enum.sort(@job_summary)

    {_link, details} = make(c.fiza_scope, {:job, c.job.id}, %{"level" => "details"})
    assert {:ok, %{item: item}} = ShareLinks.open(farah, details, @now)
    assert item.description_md == "Go and PostgreSQL."
    refute Map.has_key?(item, :history)

    Core.Jobs.update(c.fiza_scope, c.job.id, %{"title" => "Senior Backend Developer"}, @now)

    {_link, history} = make(c.fiza_scope, {:job, c.job.id}, %{"level" => "details_history"})
    assert {:ok, %{item: item}} = ShareLinks.open(farah, history, @now)
    assert item.title == "Senior Backend Developer"
    assert [%{action: "updated", by: %{name: "Fiza"}, at: @now}] = item.history
  end

  test "a customer, another organisation, an unknown, expired or revoked link: not found", c do
    {link, token} =
      make(c.fiza_scope, {:job, c.job.id}, %{"level" => "summary", "expires_in_days" => 1})

    farah = scope_for(c.farah)

    assert {:ok, _shared} = ShareLinks.open(farah, token, @now)
    assert ShareLinks.open(customer_scope_for(c.tanweer), token, @now) == {:error, :not_found}

    other = organisation_fixture()
    assert ShareLinks.open(scope_for(admin_fixture(other)), token, @now) == {:error, :not_found}
    assert ShareLinks.open(farah, "nonsense", @now) == {:error, :not_found}
    assert ShareLinks.open(farah, token, DateTime.add(@now, 1, :day)) == {:error, :not_found}

    assert {:ok, %{revoked_at: @now}} = ShareLinks.revoke(c.fiza_scope, link.id, @now)
    assert ShareLinks.open(farah, token, @now) == {:error, :not_found}
  end

  test "an opening is audited once per person per link per day", c do
    {link, token} = make(c.fiza_scope, {:task, c.task.id})

    assert {:ok, _} = ShareLinks.open(scope_for(c.farah), token, @now)
    assert {:ok, _} = ShareLinks.open(scope_for(c.farah), token, DateTime.add(@now, 1, :hour))
    assert [%{actor_user_id: farah_id}] = opened(c, link)
    assert farah_id == c.farah.id

    assert {:ok, _} = ShareLinks.open(scope_for(c.bilal), token, @now)
    assert {:ok, _} = ShareLinks.open(scope_for(c.farah), token, DateTime.add(@now, 1, :day))
    assert length(opened(c, link)) == 3
  end

  test "revoked by its maker, a lead of the item's team or an admin; refused in words to others",
       c do
    {link, _token} = make(c.fiza_scope, {:job, c.job.id})

    assert ShareLinks.revoke(scope_for(c.muaz), link.id, @now) ==
             {:error,
              {:forbidden, "Only whoever made this link, or a team lead, can turn it off."}}

    assert ShareLinks.revoke(scope_for(c.farah), link.id, @now) == {:error, :not_found}
    assert {:ok, %{revoked_at: @now}} = ShareLinks.revoke(scope_for(c.bilal), link.id, @now)

    assert {:ok, %{revoked_at: @now}} =
             ShareLinks.revoke(scope_for(c.bilal), link.id, DateTime.add(@now, 1, :hour))

    assert [%{action: "share_link_created"}, %{action: "share_link_revoked", actor_user_id: by}] =
             Audit.list_for_subject(c.org.id, "share_links", link.id)

    assert by == c.bilal.id

    {other, _token} = make(c.fiza_scope, {:task, c.task.id})
    assert {:ok, _revoked} = ShareLinks.revoke(scope_for(c.dawud), other.id, @now)
  end

  describe "a lead (AQ-04A QP4a-20)" do
    setup c do
      {:ok, sheet} =
        Core.Leads.create(
          c.fiza_scope,
          %{"job_id" => c.job.id, "profile_id" => c.golang.id, "as" => "apply"},
          @now
        )

      {:ok, _held} =
        Act.run(
          c.fiza_scope,
          :hold,
          sheet.id,
          %{
            "from" => %{"state" => "in_progress", "stage" => "applied"},
            "hold_reason" => "Waiting"
          },
          @now
        )

      %{lead: sheet}
    end

    test "each level shows its fields and no more; opened from another team; a customer finds nothing",
         c do
      {summary, s_token} = make(c.fiza_scope, {:lead, c.lead.id})
      assert summary.lead_id == c.lead.id
      {:ok, shared} = ShareLinks.open(scope_for(c.farah), s_token, @now)
      assert shared.subject == :lead and shared.team.name == "Backend squad"

      assert Map.keys(shared.item) |> Enum.sort() ==
               Enum.sort(
                 ~w(id title company profile customer state stage outcome owner applied_at last_activity_at)a
               )

      assert shared.item.title == "Backend Developer" and shared.item.stage == %{name: "Applied"}

      {_d, d_token} = make(c.fiza_scope, {:lead, c.lead.id}, %{"level" => "details"})
      {:ok, %{item: details}} = ShareLinks.open(scope_for(c.hira), d_token, @now)
      assert details.hold_reason == "Waiting" and length(details.recent) == 2
      refute Map.has_key?(details, :history)
      assert details.can.move == false

      {_h, h_token} = make(c.fiza_scope, {:lead, c.lead.id}, %{"level" => "details_history"})
      {:ok, %{item: history}} = ShareLinks.open(scope_for(c.qasim), h_token, @now)
      assert Enum.map(history.history, & &1.kind) == [:state_moved, :applied]

      assert ShareLinks.open(customer_scope_for(c.tanweer), h_token, @now) == {:error, :not_found}
      assert {:ok, [_, _, _]} = ShareLinks.list(c.fiza_scope, {:lead, c.lead.id})
      assert ShareLinks.list(scope_for(c.farah), {:lead, c.lead.id}) == {:error, :not_found}
    end

    test "revoked by its maker or a team lead; a member who sees it is refused in words", c do
      {link, _token} = make(c.fiza_scope, {:lead, c.lead.id})

      assert ShareLinks.revoke(scope_for(c.muaz), link.id, @now) ==
               {:error,
                {:forbidden, "Only whoever made this link, or a team lead, can turn it off."}}

      assert ShareLinks.revoke(scope_for(c.farah), link.id, @now) == {:error, :not_found}
      assert {:ok, %{revoked_at: @now}} = ShareLinks.revoke(scope_for(c.hira), link.id, @now)
    end
  end
end
