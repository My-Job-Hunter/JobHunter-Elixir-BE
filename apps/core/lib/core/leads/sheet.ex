defmodule Core.Leads.Sheet do
  @moduledoc """
  What a lead looks like (AQ-04A §8.3, §8.4): the **card** of the boards, the
  **row** of the job's panel, the **sheet**, the ledger's **event**, and the
  **customer's** row and sheet. `ApiShared.LeadsJSON` lists the fields; this
  module fills them, because what a person sees depends on who they are:
  `can` is `Core.Access`'s answer, and **the customer's view is cut here, in
  the context** (CONVENTIONS §2) — no owner as an account, no team, no
  priority or pin, no hold or apply-again reason, no staff-only event, staff
  by first name only when the lead's team shows names (else "The team").

  Every lead given here carries `Data.Leads.base_preload/0`; the sheet's
  also `Data.Leads.sheet/1`'s people and CV.
  """

  alias Core.Access
  alias Core.Contacts.LeadLinks
  alias Core.Jobs.Sheet, as: JobSheet
  alias Core.Leads.{Pipelines, Signals}
  alias Core.Tasks.{Cards, Person, Visibility}
  alias Data.LeadNotes
  alias Data.Leads, as: Store
  alias Data.Leads.{Event, Lead}
  alias Data.Scope
  alias Data.Tasks, as: TaskStore
  alias Data.Teams

  @recent 10
  @verbs ~w(apply apply_again move hold resume finish reopen archive unarchive pin unpin assign cv
            pipeline edit share)a

  # ── The card, the row ───────────────────────────────────────────────────────

  @doc """
  The boards' card (§8.3); `today` is the organisation's day, for
  `resume_due`. With `signals` (`Core.Leads.Signals.for_lead/2`) it carries
  P4b's `next`, `follow_up`, `quiet` and `labels` too (AQ-04B §9, §7.5).
  """
  @spec card(Lead.t(), Date.t(), map() | nil) :: map()
  def card(%Lead{} = lead, %Date{} = today, signals \\ nil) do
    job = lead.job

    %{
      id: lead.id,
      team: job.team && %{id: job.team.id, name: job.team.name},
      state: lead.state,
      stage: Pipelines.stage(lead.stage),
      progress: progress(lead),
      outcome: lead.outcome,
      priority: lead.priority,
      is_pinned: lead.is_pinned,
      archived_at: lead.archived_at,
      job: %{
        id: job.id,
        title: job.title,
        company: job.company && %{id: job.company.id, name: job.company.name},
        source: job.source,
        workplace: job.workplace,
        engagement: job.engagement,
        money: JobSheet.money(job)
      },
      profile: profile_ref(lead.profile),
      customer: customer_ref(lead.profile.customer),
      owner: Person.view(lead.owner_user),
      last_activity_at: lead.last_activity_at,
      hold_until_on: lead.hold_until_on,
      resume_due:
        lead.state == :on_hold and not is_nil(lead.hold_until_on) and
          Date.compare(lead.hold_until_on, today) != :gt
    }
    |> Map.merge(signals || %{})
  end

  @doc "The stage's place among its version's stages, for the dots: `{at, of}` (0 before a stage)."
  @spec progress(Lead.t()) :: map()
  def progress(%Lead{pipeline_version: %{stages: stages}, stage_id: stage_id}) do
    at =
      case Enum.find_index(stages, &(&1.id == stage_id)) do
        nil -> 0
        i -> i + 1
      end

    %{at: at, of: length(stages)}
  end

  @doc "The job's panel row (§8.3)."
  @spec row(Lead.t()) :: map()
  def row(%Lead{} = lead) do
    %{
      id: lead.id,
      profile: profile_ref(lead.profile),
      customer: customer_ref(lead.profile.customer),
      owner: Person.view(lead.owner_user),
      state: lead.state,
      stage: Pipelines.stage(lead.stage),
      outcome: lead.outcome,
      applied_at: lead.applied_at,
      last_activity_at: lead.last_activity_at
    }
  end

  # ── The sheet ───────────────────────────────────────────────────────────────

  @doc "The lead's sheet as `scope` sees it, at `now` (§8.3)."
  @spec sheet(Scope.t(), Lead.t(), DateTime.t()) :: map()
  def sheet(%Scope{} = scope, %Lead{} = lead, %DateTime{} = now) do
    lead = Store.sheet(lead)
    events = Store.events(lead.id, @recent)
    signals = scope.organisation |> Signals.context([lead], now) |> Signals.for_lead(lead)

    lead
    |> card(today(scope, now), signals)
    |> Map.merge(facts(lead))
    |> Map.merge(%{
      applied_by: Person.view(lead.applied_by_user),
      hold_reason: lead.hold_reason,
      held_at: lead.held_at,
      outcome_note: lead.outcome_note,
      archive_reason: lead.archive_reason,
      pipeline: Pipelines.view(scope, lead.pipeline_version),
      job: JobSheet.row(lead.job, nil),
      recent: Enum.map(events, &event/1),
      created_by: Person.view(lead.created_by_user),
      can: can(scope, lead),
      tasks: tasks(scope, lead, now),
      notes_count: Map.get(LeadNotes.counts([lead.id]), lead.id, 0)
    })
    |> Map.merge(conversation_parts(scope, lead, now))
  end

  # AQ-06 §11.6: the Recruiters tab's people, the platform tabs' and the
  # Meetings tab's counts, and the banner (the next scheduled meeting);
  # AQ-07 the Approvals tab's count (shown when it has something).
  defp conversation_parts(scope, lead, now) do
    counts = Data.Conversations.platform_counts(lead.id)
    known = Map.take(counts, [:email, :linkedin, :upwork])

    %{
      recruiters: LeadLinks.recruiters(scope, lead.id),
      tabs: %{
        email: Map.get(known, :email, 0),
        linkedin: Map.get(known, :linkedin, 0),
        upwork: Map.get(known, :upwork, 0),
        other: counts |> Map.drop([:email, :linkedin, :upwork]) |> Map.values() |> Enum.sum(),
        meetings: Data.Meetings.count_for_lead(lead.id),
        approvals: Core.Approvals.count_for_lead(scope, lead)
      },
      banner: banner(scope, lead, now)
    }
  end

  defp banner(scope, lead, now) do
    case Map.get(Data.Meetings.next_for_leads([lead.id], now), lead.id) do
      nil -> nil
      meeting -> Core.Meetings.view(scope, Data.Meetings.reload(meeting))
    end
  end

  # AQ-04B §8.1: the tasks linked to the lead that the reader sees, as
  # P2's cards.
  defp tasks(scope, lead, now) do
    tasks = TaskStore.for_lead(Visibility.filter(scope), lead.id)
    ctx = Cards.context(scope, tasks, now)
    Enum.map(tasks, &Cards.card(ctx, &1))
  end

  defp facts(lead) do
    %{
      applied_at: lead.applied_at,
      applied_via: lead.applied_via,
      applied_confirmation: lead.applied_confirmation,
      cv: cv(lead.document),
      cover_letter_md: lead.cover_letter_md,
      bid: money(lead.bid_minor, lead.bid_currency, lead.bid_period),
      connects_spent: lead.connects_spent,
      expectation:
        money(lead.expectation_minor, lead.expectation_currency, lead.expectation_period),
      finished_at: lead.finished_at
    }
  end

  @doc """
  The ledger's row (§8.3), as staff read it, with P4b's `task_id` and
  `note_id`, AQ-06's `message_id`, `meeting_id`, `contact_id` and
  `conversation_id`, and AQ-07's `approval_id`. A `note_added` row reads its note's body as `note` (nil once
  the note is deleted), so History shows the note where it was added.
  """
  @spec event(Event.t()) :: map()
  def event(%Event{} = e) do
    %{
      id: e.id,
      kind: e.kind,
      occurred_at: e.occurred_at,
      actor: %{kind: e.actor_kind, person: Person.view(e.actor_user)},
      from_label: e.from_label,
      to_label: e.to_label,
      outcome: e.outcome,
      note: event_note(e),
      is_again: e.is_again,
      task_id: e.task_id,
      note_id: e.note_id,
      message_id: e.message_id,
      meeting_id: e.meeting_id,
      contact_id: e.contact_id,
      conversation_id: e.conversation_id,
      approval_id: e.approval_id
    }
  end

  defp event_note(%Event{kind: :note_added, lead_note: %{body_md: body}}), do: body
  defp event_note(%Event{kind: :note_added}), do: nil
  defp event_note(%Event{note: note}), do: note

  @doc "Every verb's answer for `scope`, `can` of the sheet: each `Core.Access`'s, where the state allows it."
  @spec can(Scope.t(), Lead.t()) :: map()
  def can(%Scope{} = scope, %Lead{} = lead) do
    subject = Core.Leads.subject(lead)
    may = &Access.can?(scope, &1, {:lead, subject})
    open? = is_nil(lead.archived_at)

    allowed = %{
      apply: lead.state == :todo and open?,
      apply_again: lead.state in [:in_progress, :on_hold, :done],
      move: open?,
      hold: lead.state == :in_progress and open?,
      resume: lead.state == :on_hold and open?,
      finish: lead.state in [:todo, :in_progress, :on_hold] and open?,
      reopen: lead.state == :done and open?,
      archive: open?,
      unarchive: not open?,
      pin: not lead.is_pinned,
      unpin: lead.is_pinned,
      assign: true,
      cv: true,
      pipeline: lead.state in [:todo, :in_progress, :on_hold],
      edit: true,
      share: true
    }

    Map.new(@verbs, &{&1, Map.fetch!(allowed, &1) and may.(&1)})
  end

  # ── The customer's view (§8.4) ──────────────────────────────────────────────

  @doc "The customer's list row: no owner, no team, no priority or pin."
  @spec customer_row(Lead.t()) :: map()
  def customer_row(%Lead{} = lead) do
    %{
      id: lead.id,
      job: %{
        id: lead.job.id,
        title: lead.job.title,
        company: lead.job.company && %{id: lead.job.company.id, name: lead.job.company.name},
        source: lead.job.source,
        workplace: lead.job.workplace,
        engagement: lead.job.engagement,
        money: JobSheet.money(lead.job)
      },
      profile: profile_ref(lead.profile),
      state: lead.state,
      stage: customer_stage(lead.stage),
      outcome: lead.outcome,
      applied_at: lead.applied_at,
      finished_at: lead.finished_at,
      last_activity_at: lead.last_activity_at
    }
  end

  @doc """
  The customer's sheet: the job (title, company, source, workplace,
  engagement, money, description, the posting's link), the profile, where
  it stands, the application's facts, the customer-visible events with no
  reason, and `can: {applied}`.
  """
  @spec customer_sheet(Scope.t(), Lead.t(), DateTime.t()) :: map()
  def customer_sheet(%Scope{} = scope, %Lead{} = lead, %DateTime{} = now) do
    lead = Store.sheet(lead)
    job = lead.job
    names? = Teams.get_settings(job.team_id).customer_sees_staff_names
    customer = lead.profile.customer

    %{
      id: lead.id,
      job: %{
        id: job.id,
        title: job.title,
        company: job.company && %{id: job.company.id, name: job.company.name},
        source: job.source,
        workplace: job.workplace,
        engagement: job.engagement,
        money: JobSheet.money(job),
        description_md: job.description_md,
        source_url: job.source_url
      },
      profile: profile_ref(lead.profile),
      state: lead.state,
      stage: customer_stage(lead.stage),
      progress: progress(lead),
      outcome: lead.outcome,
      applied_at: lead.applied_at,
      applied_via: lead.applied_via,
      cv: cv(lead.document),
      cover_letter_md: lead.cover_letter_md,
      bid: money(lead.bid_minor, lead.bid_currency, lead.bid_period),
      expectation:
        money(lead.expectation_minor, lead.expectation_currency, lead.expectation_period),
      finished_at: lead.finished_at,
      last_activity_at: lead.last_activity_at,
      events:
        for(
          e <- Store.events(lead.id),
          e.visibility == :customer,
          do: customer_event(e, customer, names?)
        ),
      can: %{applied: Access.can?(scope, :applied, {:lead, Core.Leads.subject(lead)})},
      tasks: customer_tasks(scope, lead, now),
      conversations: customer_conversations(scope, lead)
    }
  end

  # AQ-06 §11.2, QP6-21: the conversation tabs when the lead's team allows
  # them (staff notes cut in `Core.Conversations`); `nil` when it doesn't.
  defp customer_conversations(scope, lead) do
    if Teams.get_settings(lead.job.team_id).customer_sees_conversations,
      do: Core.Conversations.of_lead(scope, lead),
      else: nil
  end

  # AQ-04B §8.2: the tasks on the lead shown to (or given to) the customer,
  # as the portal's cards.
  defp customer_tasks(scope, lead, now) do
    tasks = TaskStore.for_lead(Visibility.filter(scope), lead.id)
    ctx = Cards.context(scope, tasks, now)
    Enum.map(tasks, &Cards.portal_card(ctx, &1))
  end

  # The customer reads no reason (a hold's, an apply-again's) and no note,
  # and no word about the extension (AQ-05 §12.2): a press there is the
  # staff member's, as any other.
  defp customer_event(e, customer, names?) do
    %{
      id: e.id,
      kind: e.kind,
      occurred_at: e.occurred_at,
      actor: %{
        kind: if(e.actor_kind == :extension, do: :user, else: e.actor_kind),
        person: Person.for_customer(e.actor_user, customer, names?)
      },
      from_label: e.from_label,
      to_label: e.to_label,
      outcome: e.outcome,
      is_again: e.is_again
    }
  end

  defp customer_stage(nil), do: nil
  defp customer_stage(stage), do: %{key: stage.key, name: stage.name, kind: stage.kind}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "The organisation's day at `now`."
  @spec today(Scope.t(), DateTime.t()) :: Date.t()
  def today(%Scope{} = scope, %DateTime{} = now) do
    case DateTime.shift_zone(now, Core.Tasks.zone(scope)) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(now)
    end
  end

  defp cv(nil), do: nil
  defp cv(document), do: %{id: document.id, label: document.label, version: document.version_no}

  @doc """
  A bid or an expectation in P3's money shape (one amount: min and max the
  same), so the screens read every sum one way — an approval's proposed
  bid and expectation too (AQ-07 §11.4); `nil` for none.
  """
  @spec money(integer() | nil, String.t() | nil, atom() | nil) :: map() | nil
  def money(nil, _currency, _period), do: nil

  def money(minor, currency, period) do
    %{
      min_minor: minor,
      max_minor: minor,
      currency: currency,
      period: period,
      source: nil,
      is_estimate: false,
      is_undisclosed: false,
      text: nil
    }
  end

  defp profile_ref(profile), do: %{id: profile.id, title: profile.title}
  defp customer_ref(customer), do: %{id: customer.id, display_name: customer.display_name}
end
