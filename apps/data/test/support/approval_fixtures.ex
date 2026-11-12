defmodule Data.Fixtures.Approvals do
  @moduledoc """
  P7's fixtures (AQ-07 §14), reached through `Data.Fixtures`
  (`approval_fixture/2`, `policy_fixture/2`). Like the rest they write
  through `Data.*`, so a row that could not exist in production cannot be
  built: an approval is in its lead's team (or, for a profile change, a
  team serving the customer), about that lead's customer, asked by the
  scope's person, with version 1 and its slots; a submitted one carries
  `submitted_at`.
  """

  alias Data.Approvals
  alias Data.Scope

  @doc """
  An approval asked by `scope`'s person: `lead:` (or `profile:` with
  `team:` for a `profile_change`), `approval_kind:` (`:other`), `title:`,
  `state:` (`:draft`; any later state is submitted), `slots:` (`[:customer
  | :team_lead | {:user, user}]`, `[:customer]` by default), `rule:`,
  `due_at:`, `auto_approve_at:`, `body_md:`, `proposed:` (the version's
  `proposed_*` columns), `media:` (media rows), `effect:`.
  """
  def approval_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now()
    {:ok, a} = Approvals.create(approval_attrs(scope, attrs, now))

    {:ok, v} =
      Approvals.add_version(
        Map.merge(attrs[:proposed] || %{}, %{
          approval_id: a.id,
          approval_kind: a.approval_kind,
          number: 1,
          body_md: attrs[:body_md] || "Please approve.",
          created_by_user_id: Scope.user_id(scope),
          inserted_at: now
        })
      )

    :ok = Approvals.put_media(v.id, Enum.map(attrs[:media] || [], & &1.id))
    :ok = Approvals.put_reviewers(a.id, Enum.map(attrs[:slots] || [:customer], &slot/1))
    Approvals.reload(a)
  end

  defp approval_attrs(scope, attrs, now) do
    state = attrs[:state] || :draft

    attrs
    |> about()
    |> Map.merge(Map.take(attrs, [:due_at, :auto_approve_at]))
    |> Map.merge(%{
      organisation_id: Scope.organisation_id(scope),
      state: state,
      title: attrs[:title] || "Approval #{System.unique_integer([:positive])}",
      rule: attrs[:rule] || :any,
      requested_by_user_id: Scope.user_id(scope),
      submitted_at: if(state in [:draft, :withdrawn], do: nil, else: now),
      effect: attrs[:effect] || :none,
      version_count: 1
    })
  end

  # A lead's approval is in its team, about its customer; a profile's in `team:`.
  defp about(%{lead: lead} = attrs) when not is_nil(lead) do
    lead = Data.Leads.reload(lead)

    %{
      approval_kind: attrs[:approval_kind] || :other,
      lead_id: lead.id,
      team_id: lead.job.team_id,
      customer_id: lead.profile.customer_id
    }
  end

  defp about(%{profile: profile, team: team} = attrs) do
    %{
      approval_kind: attrs[:approval_kind] || :profile_change,
      profile_id: profile.id,
      team_id: team.id,
      customer_id: profile.customer_id
    }
  end

  defp slot({:user, user}), do: %{slot: :user, user_id: user.id}
  defp slot(slot) when slot in [:customer, :team_lead], do: %{slot: slot, user_id: nil}

  @doc "A customer's override for `approval_kind:` (`:reply`): `needs:` (`:both`), `rule:` (`:all`), `auto_approve_hours:`."
  def policy_fixture(customer, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, policy} =
      Approvals.put_policy(%{
        organisation_id: customer.organisation_id,
        customer_id: customer.id,
        approval_kind: attrs[:approval_kind] || :reply,
        needs: attrs[:needs] || :both,
        rule: attrs[:rule] || :all,
        auto_approve_hours: attrs[:auto_approve_hours]
      })

    policy
  end
end
