defmodule Core.Approvals.Sheet do
  @moduledoc """
  What an approval looks like (AQ-07 §11.4): the **approval row** of the
  page, the **approval** (the sheet), the **version**, the **slot**, the
  **comment** and the effect's words. `ApiShared.ApprovalsJSON` lists the
  fields; this module fills them, because what a person sees depends on who
  they are: `can` is `Core.Access`'s answer where the state allows it, and
  **the customer's view is cut here** — `team: null`, staff by first name
  when the team shows names (else "The team"), `can` only `decide` and
  `comment`.

  Every approval given here carries `Data.Approvals.preload/0`.
  """

  alias Core.Access
  alias Core.Access.Approvals, as: ApprovalAccess
  alias Core.Approvals.{Diff, Rule}
  alias Core.Leads.Sheet, as: LeadSheet
  alias Core.Markdown
  alias Core.Media
  alias Core.Tasks.Person
  alias Data.Approvals, as: Store
  alias Data.Approvals.{Approval, Version}
  alias Data.Scope
  alias Data.Teams

  @sent_kinds [:reply, :proposal, :cover_letter]

  # ── Versions and slots ──────────────────────────────────────────────────────

  @doc "The current version."
  @spec current(Approval.t()) :: Version.t()
  def current(%Approval{} = a), do: Enum.find(a.versions, &(&1.number == a.version_count))

  @doc "The decisions on version `number`."
  @spec decisions_on(Approval.t(), integer()) :: [map()]
  def decisions_on(%Approval{} = a, number),
    do: Enum.filter(a.decisions, &(&1.version_number == number))

  @doc "The slots still open on the current version: none unless it is pending."
  @spec open_slots(Approval.t()) :: [map()]
  def open_slots(%Approval{state: :pending} = a),
    do: Rule.open(a.reviewers, decisions_on(a, a.version_count))

  def open_slots(%Approval{}), do: []

  @doc "What `Core.Access.Approvals` decides on."
  @spec subject(Approval.t()) :: map()
  def subject(%Approval{} = a) do
    %{
      id: a.id,
      organisation_id: a.organisation_id,
      team_id: a.team_id,
      customer_id: a.customer_id,
      state: a.state,
      requested_by_user_id: a.requested_by_user_id,
      slots: Enum.map(a.reviewers, &%{id: &1.id, slot: &1.slot, user_id: &1.user_id}),
      lead: a.lead && Core.Leads.subject(a.lead)
    }
  end

  @doc "Whether an open slot of `a` is the caller's to decide: *Waiting on me*."
  @spec waiting_on_me?(Scope.t(), Approval.t()) :: boolean()
  def waiting_on_me?(%Scope{} = scope, %Approval{} = a),
    do: ApprovalAccess.waiting_on?(scope, subject(a), open_slots(a))

  # ── The row, the approval ───────────────────────────────────────────────────

  @doc "The **approval row** (§11.4) as `scope` reads it at `now`."
  @spec row(Scope.t(), Approval.t(), DateTime.t()) :: map()
  def row(%Scope{} = scope, %Approval{} = a, %DateTime{} = now) do
    who = people(scope, a)

    %{
      id: a.id,
      approval_kind: a.approval_kind,
      state: a.state,
      title: a.title,
      customer: %{id: a.customer.id, display_name: a.customer.display_name},
      lead: lead_ref(a.lead),
      profile: a.profile && %{id: a.profile.id, title: a.profile.title},
      requested_by: who.(a.requested_by_user),
      due_at: a.due_at,
      overdue: overdue?(a, now),
      version: a.version_count,
      waiting_on: Enum.map(open_slots(a), &%{slot: &1.slot, person: slot_person(who, &1, nil)}),
      effect: effect(a),
      updated_at: a.updated_at
    }
  end

  @doc "The **approval** (§11.4): the row, the slots, the current version, the versions, the diff, `can`."
  @spec approval(Scope.t(), Approval.t(), DateTime.t()) :: map()
  def approval(%Scope{} = scope, %Approval{} = a, %DateTime{} = now) do
    who = people(scope, a)
    current = current(a)
    decided = Map.new(decisions_on(a, a.version_count), &{&1.approval_reviewer_id, &1})
    open = MapSet.new(open_slots(a), & &1.id)
    skills = skill_names(a)

    scope
    |> row(a, now)
    |> Map.merge(%{
      team: if(Scope.customer?(scope), do: nil, else: %{id: a.team.id, name: a.team.name}),
      rule: a.rule,
      slots: Enum.map(a.reviewers, &slot(who, &1, decided[&1.id], MapSet.member?(open, &1.id))),
      current: version(who, current, skills),
      versions:
        Enum.map(
          a.versions,
          &%{number: &1.number, at: &1.inserted_at, by: who.(&1.created_by_user)}
        ),
      diff: diff(a, current, skills),
      submitted_at: a.submitted_at,
      decided_at: a.decided_at,
      comments_count: Map.get(Store.comment_counts([a.id]), a.id, 0),
      can: can(scope, a)
    })
  end

  defp slot(who, reviewer, decision, open?) do
    %{
      id: reviewer.id,
      slot: reviewer.slot,
      person: slot_person(who, reviewer, decision),
      decision:
        decision &&
          %{
            decision: decision.decision,
            note: decision.note,
            by: who.(decision.decided_by_user),
            at: decision.decided_at
          },
      open: open?
    }
  end

  # A named slot reads as its person; a customer or team-lead slot as whoever took it.
  defp slot_person(who, %{slot: :user} = reviewer, _decision), do: who.(reviewer.user)
  defp slot_person(_who, _reviewer, nil), do: nil
  defp slot_person(who, _reviewer, decision), do: who.(decision.decided_by_user)

  @doc "A **version** (§11.4)."
  @spec version((map() | nil -> map() | nil), Version.t(), map()) :: map()
  def version(who, %Version{} = v, skills) do
    %{
      number: v.number,
      body_md: v.body_md,
      body_html: Markdown.to_html(v.body_md),
      proposed: %{
        document: v.proposed_document && document_ref(v.proposed_document),
        bid:
          LeadSheet.money(v.proposed_bid_minor, v.proposed_bid_currency, v.proposed_bid_period),
        connects: v.proposed_connects,
        expectation:
          LeadSheet.money(
            v.proposed_expectation_minor,
            v.proposed_expectation_currency,
            v.proposed_expectation_period
          ),
        title: v.proposed_title,
        headline: v.proposed_headline,
        summary: v.proposed_summary,
        skills:
          for(id <- v.proposed_skill_ids || [], name = skills[id], do: %{id: id, name: name})
      },
      attachments: Enum.map(v.media_links, &attachment/1),
      by: who.(v.created_by_user),
      at: v.inserted_at
    }
  end

  defp attachment(link) do
    %{
      media_id: link.media_id,
      filename: link.media.original_filename,
      content_type: link.media.content_type,
      url: Media.link(link.media_id)
    }
  end

  # §6: between the current version and the one before; `[]` for version 1.
  defp diff(_a, %Version{number: 1}, _skills), do: []

  defp diff(a, current, skills) do
    case Enum.find(a.versions, &(&1.number == current.number - 1)) do
      nil -> []
      before -> Diff.between(words(before, skills), words(current, skills))
    end
  end

  defp words(v, skills) do
    %{
      body_md: v.body_md,
      document:
        v.proposed_document && "#{v.proposed_document.label} · v#{v.proposed_document.version_no}",
      bid: money_line(v.proposed_bid_minor, v.proposed_bid_currency, v.proposed_bid_period),
      connects: v.proposed_connects && "#{v.proposed_connects} Connects",
      expectation:
        money_line(
          v.proposed_expectation_minor,
          v.proposed_expectation_currency,
          v.proposed_expectation_period
        ),
      title: v.proposed_title,
      headline: v.proposed_headline,
      summary: v.proposed_summary,
      skills:
        v.proposed_skill_ids && Enum.map_join(v.proposed_skill_ids, ", ", &(skills[&1] || "?"))
    }
  end

  defp money_line(nil, _currency, _period), do: nil

  defp money_line(minor, currency, period),
    do:
      Utils.Money.line(%{min_minor: minor, max_minor: minor, currency: currency, period: period})

  defp skill_names(a) do
    ids = a.versions |> Enum.flat_map(&(&1.proposed_skill_ids || [])) |> Enum.uniq()

    if ids == [],
      do: %{},
      else:
        a.organisation_id
        |> Data.Skills.list(ids: ids, include_archived: true)
        |> Map.new(&{&1.id, &1.name})
  end

  @doc "A **comment** (§11.4) as `scope` reads it."
  @spec comment(Scope.t(), Approval.t(), map()) :: map()
  def comment(%Scope{} = scope, %Approval{} = a, c) do
    subject = %{author_user_id: c.author_user_id, approval: subject(a)}

    %{
      id: c.id,
      body_md: c.body_md,
      author: people(scope, a).(c.author_user),
      at: c.inserted_at,
      deleted: not is_nil(c.deleted_at),
      can: %{
        delete: is_nil(c.deleted_at) and Access.can?(scope, :delete, {:approval_comment, subject})
      }
    }
  end

  # ── `can`, the effect ───────────────────────────────────────────────────────

  # Each verb where the state allows it and `Core.Access` says yes; the
  # customer's only `decide` and `comment`.
  defp can(scope, a) do
    may = &Access.can?(scope, &1, {:approval, subject(a)})
    customer? = Scope.customer?(scope)

    Map.new(allowed(scope, a), fn {verb, ok?} ->
      action = if verb == :decide, do: :read, else: verb
      {verb, ok? and (not customer? or verb in [:decide, :comment]) and may.(action)}
    end)
  end

  defp allowed(scope, a) do
    mine? = not is_nil(a.requested_by_user_id) and a.requested_by_user_id == Scope.user_id(scope)

    %{
      edit: a.state == :draft,
      submit: a.state == :draft,
      decide: a.state == :pending and waiting_on_me?(scope, a),
      revise: a.state == :changes_requested or (a.state == :pending and mine?),
      withdraw: a.state in [:draft, :pending, :changes_requested],
      comment: true,
      sent: a.state == :approved and a.effect == :ready and a.approval_kind in @sent_kinds
    }
  end

  @doc "The effect (§7, §11.4): `%{state, words}`, the words `nil` when there is nothing to say."
  @spec effect(Approval.t()) :: map()
  def effect(%Approval{} = a), do: %{state: a.effect, words: effect_words(a)}

  defp effect_words(%Approval{effect: :failed, effect_note: note}),
    do: "Approved, but couldn't apply: #{note}."

  defp effect_words(%Approval{effect: :sent}), do: "Recorded as sent."

  defp effect_words(%Approval{effect: :ready, approval_kind: kind}) do
    case kind do
      :proposal -> "Approved: ready to send. The bid is stored on the lead."
      :cover_letter -> "Approved: ready to send. The letter is on the lead."
      _reply -> "Approved: ready to send."
    end
  end

  defp effect_words(%Approval{effect: :applied} = a) do
    case a.approval_kind do
      :cv_for_job -> "Approved. #{cv_label(a)} is now the CV for this lead."
      :rate -> "Approved. The expectation is set on the lead."
      :asset -> "Approved. Its files are on the lead."
      :profile_change -> "Approved. The changes are applied to #{a.profile && a.profile.title}."
      _other -> "Approved."
    end
  end

  defp effect_words(%Approval{state: :approved, approval_kind: :other}),
    do: "Approved. Nothing is applied automatically."

  defp effect_words(_a), do: nil

  defp cv_label(a) do
    case current(a).proposed_document do
      %{label: label} -> label
      nil -> "The CV"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "A state as the screens say it (§12.3)."
  @spec state_words(atom()) :: String.t()
  def state_words(:draft), do: "Draft"
  def state_words(:pending), do: "Waiting"
  def state_words(:approved), do: "Approved"
  def state_words(:changes_requested), do: "Changes requested"
  def state_words(:rejected), do: "Rejected"
  def state_words(:withdrawn), do: "Withdrawn"
  def state_words(:expired), do: "Expired"

  @doc "Whether a pending approval is past its due time at `now`."
  @spec overdue?(Approval.t(), DateTime.t()) :: boolean()
  def overdue?(%Approval{state: :pending, due_at: %DateTime{} = due}, now),
    do: DateTime.before?(due, now)

  def overdue?(_a, _now), do: false

  @doc """
  How `scope` reads a person of `a`: staff see staff as they are and the
  customer by their name; the customer sees themselves, and staff by first
  name when the team shows names, else "The team".
  """
  @spec people(Scope.t(), Approval.t()) :: (map() | nil -> map() | nil)
  def people(%Scope{} = scope, %Approval{} = a) do
    if Scope.customer?(scope) do
      names? = Teams.get_settings(a.team_id).customer_sees_staff_names
      &Person.for_customer(&1, a.customer, names?)
    else
      &Person.view(&1, customer: a.customer)
    end
  end

  @doc "The lead as an approval names it: `{id, title}`, the title the job's (and its company's)."
  @spec lead_ref(map() | nil) :: map() | nil
  def lead_ref(nil), do: nil

  def lead_ref(lead) do
    title =
      case lead.job.company do
        %{name: name} -> "#{lead.job.title} · #{name}"
        _none -> lead.job.title
      end

    %{id: lead.id, title: title}
  end

  defp document_ref(d), do: %{id: d.id, label: d.label, version: d.version_no}
end
