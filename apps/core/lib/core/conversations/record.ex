defmodule Core.Conversations.Record do
  @moduledoc """
  What every conversation write records on its leads (AQ-06 §5.4, §11.6),
  inside the write's transaction — by hand, from an `.eml`, from the
  extension, from triage:

  - **a link** (`link/6`): `conversation_leads` with its method and
    confidence; `conversation_linked` (staff) on the lead; the
    conversation's customer set from the lead's; and, when the
    conversation had messages, their `message_in` / `message_out` dated as
    sent, so History and the follow-ups read them; an invitation its mails
    carry proposes a meeting on the lead then (AQ-09 §9,
    `Core.Meetings.Proposals.on_link/4`). **A conversation links only to
    its own team's leads, about one customer.**
  - **a message** (`message/4`): `message_in` / `message_out` on each of
    its leads — customer-visible when the team has
    `customer_sees_conversations` on, staff-only otherwise, and never for a
    staff note — a person's act (activity), the extension's with the
    person (P5); an inbound one tells the lead's owner
    (`conversations.reply_received`) and clears its follow-ups
    (`Core.Leads.FollowUps`).

  Each answers the realtime events after commit: `message_added` and
  `lead_updated` on the lead, `triage_changed` on the team when the
  conversation is in its triage.
  """

  alias Core.Conversations.Notices
  alias Core.Leads
  alias Core.Leads.{Ledger, Words}
  alias Core.Meetings.Proposals
  alias Core.Realtime
  alias Data.Conversations, as: Store
  alias Data.Conversations.{Conversation, Message}
  alias Data.Leads, as: LeadStore
  alias Data.Scope
  alias Data.Teams

  @doc """
  Links `conversation` to `lead` (`method`, `confidence`). Answers
  `{:ok, :linked | :kept, events}`, or the field error for another team's
  or another customer's lead.
  """
  @spec link(Scope.t(), Conversation.t(), map(), atom(), atom(), DateTime.t()) ::
          {:ok, :linked | :kept, list()} | {:error, term()}
  def link(%Scope{} = scope, %Conversation{} = c, lead, method, confidence, %DateTime{} = now) do
    with :ok <- same_team(c, lead),
         :ok <- same_customer(c, lead),
         {:ok, how} <-
           Store.link(%{
             conversation_id: c.id,
             lead_id: lead.id,
             match_method: method,
             confidence: confidence,
             linked_by_user_id: Scope.user_id(scope)
           }) do
      if how == :kept, do: {:ok, :kept, []}, else: linked(scope, c, lead, now)
    end
  end

  defp linked(scope, c, lead, now) do
    {:ok, _c} = put_customer(c, lead)
    labels = %{conversation_id: c.id, to_label: title(c), from_label: Words.value(c.platform)}
    _event = Ledger.record(scope, lead, :conversation_linked, labels, now)

    for m <- Store.messages([c.id]),
        not m.is_internal,
        is_nil(m.deleted_at),
        do: event(scope, c, lead, m, now)

    {:ok, :linked,
     [
       Realtime.lead_events("lead_updated", lead),
       Realtime.message_added(lead.id, c.id),
       Realtime.triage_changed(c.team_id),
       Proposals.on_link(scope, c, lead, now)
     ]}
  end

  defp same_team(c, lead) do
    if lead.job.team_id == c.team_id,
      do: :ok,
      else:
        Leads.invalid(
          "lead_id",
          "is in another team: a conversation links only to its own team's leads"
        )
  end

  defp same_customer(%{customer_id: nil}, _lead), do: :ok
  defp same_customer(%{customer_id: id}, %{profile: %{customer_id: id}}), do: :ok

  defp same_customer(_c, _lead),
    do: Leads.invalid("lead_id", "is another customer's: a conversation is about one customer")

  defp put_customer(%{customer_id: nil} = c, lead),
    do: Store.update(c, %{customer_id: lead.profile.customer_id})

  defp put_customer(c, _lead), do: {:ok, c}

  @doc """
  A message arrived in `conversation` (already inserted): its events on
  each lead, the owner told of an inbound one. Answers the realtime events.
  """
  @spec message(Scope.t(), Conversation.t(), Message.t(), DateTime.t()) :: list()
  def message(%Scope{} = scope, %Conversation{} = c, %Message{} = m, %DateTime{} = now) do
    :ok = Store.touch(c.id, m.sent_at)
    leads = leads(c)
    m = Data.Repo.preload(m, [:from_contact])

    told =
      for lead <- leads, not m.is_internal do
        _event = event(scope, c, lead, m, now)

        notice =
          if m.direction == :in,
            do: Notices.reply_received(scope, lead, m, Notices.who(m)),
            else: []

        [notice, Realtime.lead_events("lead_updated", lead)]
      end

    [
      told,
      Enum.map(leads, &Realtime.message_added(&1.id, c.id)),
      if(leads == [], do: [Realtime.triage_changed(c.team_id)], else: [])
    ]
  end

  @doc "The realtime events for a change to a message already there (an edit, a delete)."
  @spec changed(Conversation.t()) :: list()
  def changed(%Conversation{} = c) do
    case leads(c) do
      [] -> [Realtime.triage_changed(c.team_id)]
      leads -> Enum.map(leads, &Realtime.message_added(&1.id, c.id))
    end
  end

  # The conversation's leads, fresh (a link may have just been made).
  defp leads(c) do
    c.id
    |> Store.lead_ids()
    |> Enum.map(&LeadStore.get(c.organisation_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp event(scope, c, lead, m, now) do
    Ledger.record(
      scope,
      lead,
      if(m.direction == :in, do: :message_in, else: :message_out),
      %{
        message_id: m.id,
        occurred_at: m.sent_at,
        from_label: Words.value(c.platform),
        to_label: other_side(m),
        visibility: visibility(c)
      },
      now
    )
  end

  defp visibility(c),
    do: if(Teams.get_settings(c.team_id).customer_sees_conversations, do: :customer, else: :staff)

  # The other side's name (never a staff member's: the customer reads it).
  defp other_side(%{direction: :in} = m), do: Notices.who(m)

  defp other_side(%{to_text: to}) when is_binary(to),
    do: Core.Conversations.names_only(to)

  defp other_side(_m), do: nil

  defp title(%{subject: subject}) when is_binary(subject) and subject != "", do: subject
  defp title(c), do: Words.value(c.platform)
end
