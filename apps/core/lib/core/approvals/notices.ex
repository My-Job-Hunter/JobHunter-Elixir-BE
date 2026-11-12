defmodule Core.Approvals.Notices do
  @moduledoc """
  Who is told about an approval (AQ-07 §10, §11.4), each row **ensured by
  its dedupe key** and naming the approval (`approval_id`), never the
  actor; in-app until P8. A row opens `/approvals/<id>?team=<team_id>` in
  the console and `/approvals/<id>` in the portal. The customer is told only with a portal login,
  and reads staff by first name when the team shows names, else "The
  team".

  | Kind (group `approvals`) | Who | Dedupe |
  |---|---|---|
  | `approvals.requested` | the slots' people (the customer; the team's leads for a *team lead* slot; a named person) | `approval:<id>:requested:<version>` |
  | `approvals.decided` | the requester, and the other reviewers, on the outcome | `approval:<id>:outcome:<state>:<version>` |
  | `approvals.commented` | the requester and the reviewers, not the author | `approval_comment:<id>` |
  | `approvals.due_soon` · `approvals.overdue` | the open slots' people (overdue: the requester too) | `approval:<id>:<kind>:<due_at>` |
  | `approvals.expired` | the requester | `approval:<id>:expired` |
  """

  alias Core.Approvals.Sheet
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Scope
  alias Data.Teams

  @doc "`approvals.requested`: on submit and on each revision."
  @spec requested(Scope.t(), map()) :: list()
  def requested(scope, a) do
    tell(
      scope,
      a,
      people(a, a.reviewers),
      "approvals.requested",
      "approval:#{a.id}:requested:#{a.version_count}",
      fn who ->
        if a.version_count == 1,
          do: "#{who} asks for your approval: #{a.title}",
          else: "#{who} sent version #{a.version_count} of #{a.title} for your approval"
      end
    )
  end

  @doc "`approvals.decided`: the outcome, to the requester and the other reviewers."
  @spec decided(Scope.t(), map()) :: list()
  def decided(scope, a) do
    who_to = requester(a) ++ people(a, a.reviewers)

    tell(
      scope,
      a,
      who_to,
      "approvals.decided",
      "approval:#{a.id}:outcome:#{a.state}:#{a.version_count}",
      fn who ->
        case {a.state, Scope.user_id(scope)} do
          {:approved, nil} -> "#{a.title} was approved automatically"
          {:approved, _by} -> "#{who} approved #{a.title}"
          {:changes_requested, _by} -> "#{who} asked for changes to #{a.title}"
          {:rejected, _by} -> "#{who} rejected #{a.title}"
        end
      end
    )
  end

  @doc "`approvals.commented`: the requester and the reviewers, not the author."
  @spec commented(Scope.t(), map(), map()) :: list()
  def commented(scope, a, comment) do
    tell(
      scope,
      a,
      requester(a) ++ people(a, a.reviewers),
      "approvals.commented",
      "approval_comment:#{comment.id}",
      fn who -> "#{who} commented on #{a.title}" end
    )
  end

  @doc "`approvals.due_soon` (24 h before) or `approvals.overdue` (at the time; the requester too)."
  @spec due(Scope.t(), map(), :due_soon | :overdue) :: list()
  def due(scope, a, kind) do
    open = people(a, Sheet.open_slots(a))
    who_to = if kind == :overdue, do: open ++ requester(a), else: open
    words = if kind == :overdue, do: "Overdue: #{a.title}", else: "Due in 24 hours: #{a.title}"

    tell(
      scope,
      a,
      who_to,
      "approvals.#{kind}",
      "approval:#{a.id}:#{kind}:#{DateTime.to_iso8601(a.due_at)}",
      fn _who -> words end
    )
  end

  @doc "`approvals.expired`: three days past due with no outcome, to the requester."
  @spec expired(Scope.t(), map()) :: list()
  def expired(scope, a) do
    tell(scope, a, requester(a), "approvals.expired", "approval:#{a.id}:expired", fn _who ->
      "#{a.title} expired with no decision"
    end)
  end

  # ── Who ─────────────────────────────────────────────────────────────────────

  @doc false
  # `[{user_id, customer?}]`: the people of these slots — the customer's
  # login, every lead of the team for a team-lead slot, a named person.
  def people(a, slots) do
    leads = fn ->
      for m <- Teams.list_members(a.team_id), m.role == :lead, do: {m.user_id, false}
    end

    slots
    |> Enum.flat_map(fn
      %{slot: :customer} -> if a.customer.user_id, do: [{a.customer.user_id, true}], else: []
      %{slot: :team_lead} -> leads.()
      %{slot: :user, user_id: id} -> [{id, false}]
    end)
    |> Enum.uniq()
  end

  defp requester(%{requested_by_user_id: nil}), do: []
  defp requester(a), do: [{a.requested_by_user_id, false}]

  # Each once, never the actor, worded for the recipient.
  defp tell(scope, a, who_to, kind, dedupe, words) do
    me = Scope.user_id(scope)
    actor = me && Accounts.get_user(me)
    names? = Teams.get_settings(a.team_id).customer_sees_staff_names

    for {user_id, customer?} <- Enum.uniq_by(who_to, &elem(&1, 0)), user_id != me do
      ensure(a, user_id, kind, dedupe,
        title: words.(who(actor, a, customer?, names?)),
        actor: if(customer? and not names?, do: nil, else: actor),
        link: link(a, customer?)
      )
    end
  end

  # Where it opens: the console's sheet in its team, the portal's sheet.
  defp link(a, true), do: "/approvals/#{a.id}"
  defp link(a, false), do: "/approvals/#{a.id}?team=#{a.team_id}"

  defp who(nil, _a, _customer?, _names?), do: "The team"

  defp who(%{id: id}, %{customer: %{user_id: id, display_name: name}}, _customer?, _names?),
    do: name

  defp who(actor, _a, true, true), do: Person.first_name(actor) || "The team"
  defp who(_actor, _a, true, false), do: "The team"
  defp who(actor, _a, false, _names?), do: Person.first_name(actor) || "Someone"

  defp ensure(a, user_id, kind, dedupe, opts) do
    {:ok, row} =
      Notifications.ensure(Scope.system(%{id: a.organisation_id}), %{
        organisation_id: a.organisation_id,
        user_id: user_id,
        notification_kind_key: kind,
        actor_user_id: opts[:actor] && opts[:actor].id,
        approval_id: a.id,
        title: opts[:title],
        link_path: opts[:link],
        dedupe_key: dedupe
      })

    if row.is_new,
      do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
