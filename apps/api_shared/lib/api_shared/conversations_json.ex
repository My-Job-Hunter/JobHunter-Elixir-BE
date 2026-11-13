defmodule ApiShared.ConversationsJSON do
  @moduledoc """
  The shapes of AQ-06 §11.6, pinned before the build so the three repos
  build to one contract: the **contact**, the contacts page, the
  **match**, the **message** (a tree), the **conversation**, the **triage
  item**, the **meeting**, the lead sheet's `recruiters`, and the answers
  of `POST /eml`, *Classify*, *Create job and lead*, *Mark as recruiter*
  and the extension's capture. `Core.Contacts`, `Core.Conversations` and
  `Core.Meetings` fill them (the customer's view is cut there); this
  module lists every field by name, so nothing reaches the wire unasked.
  Keys are snake_case, no map is keyed by data, optional members are
  `null`.
  """

  @person ~w(user_id name photo_url)a
  @contact ~w(id name title company time_zone location source handles is_do_not_contact notes_md
              merged_into created_by can)a

  # ── Contacts ────────────────────────────────────────────────────────────────

  @doc "**contact**: with its `leads: [{id, title, company, role, state}]`."
  def contact(c) do
    c
    |> base_contact()
    |> Map.put(:leads, Enum.map(c.leads, &Map.take(&1, [:id, :title, :company, :role, :state])))
  end

  @doc "A contacts page row: the contact without `leads`, with `leads_count`."
  def contact_row(c), do: c |> base_contact() |> Map.put(:leads_count, c.leads_count)

  defp base_contact(c) do
    c
    |> Map.take(@contact)
    |> Map.update!(
      :handles,
      &Enum.map(&1, fn h -> Map.take(h, [:id, :kind, :value, :is_invalid]) end)
    )
    |> Map.update!(:created_by, &person/1)
    |> Map.update!(:can, &Map.take(&1, [:edit, :merge]))
  end

  @doc "**contacts page**: `{items, next_cursor}`."
  def contacts(page),
    do: %{items: Enum.map(page.items, &contact_row/1), next_cursor: page.next_cursor}

  @doc "**match**: `{answer, contact?, candidates}`."
  def match(m) do
    %{
      answer: m.answer,
      contact: m.contact && contact(m.contact),
      candidates: Enum.map(m.candidates, &contact/1)
    }
  end

  @doc "The lead sheet's `recruiters` row: `{contact (a contacts page row), role}`."
  def recruiter(r), do: %{contact: contact_row(r.contact), role: r.role}

  # ── Conversations ───────────────────────────────────────────────────────────

  @doc "**message**, with its `children` (a tree); `parent_missing` marks a parent not held."
  def message(m) do
    %{
      id: m.id,
      direction: m.direction,
      is_internal: m.is_internal,
      from: %{
        kind: m.from.kind,
        contact: m.from.contact,
        person: person(m.from.person),
        text: m.from.text
      },
      to_text: m.to_text,
      sent_at: m.sent_at,
      body_text: m.body_text,
      body_html: m.body_html,
      parent_id: m.parent_id,
      captured_via: m.captured_via,
      invite: m.invite,
      classification: m.classification,
      attachments:
        Enum.map(m.attachments, &Map.take(&1, [:media_id, :filename, :content_type, :url])),
      deleted: m.deleted,
      parent_missing: m.parent_missing,
      can: Map.take(m.can, [:edit, :delete, :classify, :reply]),
      children: Enum.map(m.children, &message/1)
    }
  end

  @doc "**conversation**: the roots of its tree, oldest first, and how many gaps."
  def conversation(c) do
    %{
      id: c.id,
      team: c.team,
      platform: c.platform,
      subject: c.subject,
      channel: c.channel,
      participants: c.participants,
      leads: Enum.map(c.leads, &Map.take(&1, [:id, :title, :match_method, :confidence])),
      last_message_at: c.last_message_at,
      ignored_at: c.ignored_at,
      messages: Enum.map(c.messages, &message/1),
      gaps: c.gaps
    }
  end

  @doc """
  **triage item**: `{conversation, first_message (no children), candidates:
  [{lead, why}], profile: {id, title}?, customer: {id, display_name}?}`
  (AQ-09 §11.4: the receiving channel's profile and customer).
  """
  def triage_item(t) do
    %{
      conversation: conversation(t.conversation),
      profile: t.profile,
      customer: t.customer,
      first_message: t.first_message && message(t.first_message),
      candidates:
        Enum.map(t.candidates, fn c ->
          %{lead: c.lead |> ApiShared.LeadsJSON.row() |> Map.put(:job, c.lead.job), why: c.why}
        end)
    }
  end

  @doc "`GET /triage`: `{team, items}`."
  def triage(page), do: %{team: page.team, items: Enum.map(page.items, &triage_item/1)}

  @doc "`POST /eml`: `{conversation, landed, leads: [{id, title}], added, already}`."
  def eml(a) do
    %{
      conversation: conversation(a.conversation),
      landed: a.landed,
      leads: a.leads,
      added: a.added,
      already: a.already
    }
  end

  @doc "*Classify*: `{message, lead: P4a's sheet?, next}`."
  def classified(a) do
    %{
      message: message(a.message),
      lead: a.lead && ApiShared.LeadsJSON.sheet(a.lead),
      next: a.next
    }
  end

  @doc "*Create job and lead*: `{lead: P4a's card, conversation}`."
  def created_lead(a),
    do: %{lead: ApiShared.LeadsJSON.card(a.lead), conversation: conversation(a.conversation)}

  @doc "*Mark as recruiter*: `{conversation, contact}`."
  def recruited(a), do: %{conversation: conversation(a.conversation), contact: contact(a.contact)}

  @doc "The extension's capture: `{conversation_id, lead_id, lead_title, triage, added, link_path}`."
  def captured(a),
    do: Map.take(a, [:conversation_id, :lead_id, :lead_title, :triage, :added, :link_path])

  # ── Meetings ────────────────────────────────────────────────────────────────

  @doc """
  **meeting**, with its `clash: {words}?`; AQ-09 §11.4's `from_message:
  {id, conversation_id, subject}?` and `proposal: {organizer, method,
  sequence, change: {starts_at, ends_at, cancel}?}?`.
  """
  def meeting(m) do
    %{
      id: m.id,
      lead: m.lead,
      title: m.title,
      meeting_kind: m.meeting_kind,
      platform: m.platform,
      join_url: m.join_url,
      address: m.address,
      starts_at: m.starts_at,
      ends_at: m.ends_at,
      time_zone: m.time_zone,
      status: m.status,
      outcome_note: m.outcome_note,
      notes_md: m.notes_md,
      attendees:
        Enum.map(m.attendees, fn a ->
          %{kind: a.kind, person: person(a.person), contact: a.contact}
        end),
      sequence: m.sequence,
      source: m.source,
      from_message: m.from_message,
      proposal: m.proposal,
      clash: m.clash,
      can: Map.take(m.can, [:reschedule, :cancel, :done, :no_show, :edit])
    }
  end

  @doc "`GET /meetings`: `{items: [meeting]}`."
  def meetings(page), do: %{items: Enum.map(page.items, &meeting/1)}

  @doc "`POST /meetings/clash`: `{clash: {words}?, stage_offer: {key, name, words}?}`."
  def clash(c), do: %{clash: c.clash, stage_offer: c.stage_offer}

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, @person)
end
