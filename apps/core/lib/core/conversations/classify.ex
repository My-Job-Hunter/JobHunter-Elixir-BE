defmodule Core.Conversations.Classify do
  @moduledoc """
  *Classify* (AQ-06 §7.3, QP6-11): a person picks the class of an inbound
  message — in triage after linking, or on a lead — and **each class
  moves the lead through P4a's own verb**, with its rules and words; the
  class is kept on the message, and a `classified` event (staff) is
  written beside the move's own, in one transaction.

  | Class | Does |
  |---|---|
  | `interested` | the lead to its pipeline's `screening` stage, when it is In progress behind it (P4a's move) |
  | `interview_invitation` | nothing yet: answers `next: "schedule_meeting"`, and the meeting's `move_to_stage` moves it |
  | `more_info` | a task for the lead's owner, "Reply to *Mei Chen*: more information", on the lead (P2's task), due `due_on` |
  | `rejection` | Done · Rejected (P4a's finish, `from` required) |
  | `position_closed` | Done · Position closed, the job closed too (P4a's finish closes it, P3's close) |
  | `unsubscribe` | the sender's contact becomes do-not-contact |
  | `bounce` | the handle it bounced from becomes invalid |
  | `general` | the label alone |

  `POST /messages/:id/classify {class, from?, due_on?, lead_id?}`:
  `lead_id` chooses among the conversation's leads when it has several.
  Answers `{message, lead: P4a's sheet or nil, next}`.
  """

  alias Core.Audit
  alias Core.Conversations
  alias Core.Conversations.{Messages, Notices, Record}
  alias Core.Leads
  alias Core.Leads.{Act, Ledger}
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: Store
  alias Data.Conversations.Message
  alias Data.Scope
  alias Data.Vocabulary

  @needs_lead [:interested, :interview_invitation, :more_info, :rejection, :position_closed]
  @words %{
    interested: "Interested",
    interview_invitation: "Interview invitation",
    more_info: "More information",
    rejection: "Rejection",
    position_closed: "Position closed",
    unsubscribe: "Unsubscribe",
    bounce: "Bounce",
    general: "General"
  }

  @doc "A class as a person reads it."
  def words(class), do: Map.fetch!(@words, class)

  @spec run(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, message, c} <- Messages.fetch(scope, :classify, id),
         :ok <- inbound(message),
         {:ok, class} <- class(params["class"]),
         {:ok, lead} <- lead(scope, c, class, params["lead_id"]) do
      fn -> labelled(scope, {c, message, lead}, class, params, now) end
      |> Write.commit()
      |> case do
        {:ok, {labelled, moved}} -> {:ok, answer(scope, c, labelled, moved, class)}
        error -> error
      end
    end
  end

  defp labelled(scope, {c, message, lead}, class, params, now) do
    with {:ok, moved} <- move(scope, class, lead, message, params, now),
         {:ok, labelled} <-
           message
           |> Message.classify_changeset(class, Scope.user_id(scope))
           |> Store.update_message() do
      classified(scope, lead, labelled, class, now)

      {:ok, _audit} =
        Audit.record(scope, "classified", labelled,
          after: %{"classification" => class, "team_id" => c.team_id},
          now: now
        )

      {:ok, {labelled, moved}, [Record.changed(c)]}
    end
  end

  defp answer(scope, c, labelled, moved, class) do
    c = Store.reload(c)
    labelled = Store.message(labelled.organisation_id, labelled.id)

    %{
      message: Conversations.node(scope, c, labelled),
      lead: moved,
      next: if(class == :interview_invitation, do: "schedule_meeting")
    }
  end

  defp inbound(%Message{direction: :in, deleted_at: nil}), do: :ok

  defp inbound(_message),
    do: Leads.invalid("id", "is not an inbound message: only a reply is classified")

  defp class(nil), do: {:error, {:missing, [:class]}}

  defp class(value) do
    if to_string(value) in Vocabulary.message_classes(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: Leads.invalid("class", "is not a class")
  end

  # The lead the class moves: the conversation's one, or `lead_id` among several.
  defp lead(scope, c, class, lead_id) do
    ids = Enum.map(c.links, & &1.lead_id)

    case Leads.blank(lead_id) do
      nil ->
        only_lead(scope, ids, class in @needs_lead)

      id ->
        if id in ids,
          do: Leads.fetch(scope, :read, id),
          else: Leads.invalid("lead_id", "is not one of this conversation's leads")
    end
  end

  defp only_lead(scope, [id], _needed?), do: Leads.fetch(scope, :read, id)
  defp only_lead(_scope, _ids, false), do: {:ok, nil}

  defp only_lead(_scope, [], true),
    do: Leads.invalid("class", "needs a lead: link this conversation first")

  defp only_lead(_scope, _several, true),
    do: Leads.invalid("lead_id", "is required: this conversation has several leads")

  # ── Each class's move, through its own verb ─────────────────────────────────

  defp move(scope, :interested, lead, _message, _params, now) do
    case screening(lead) do
      nil ->
        sheet(scope, lead, now)

      stage ->
        Act.run(
          scope,
          :move,
          lead.id,
          %{from: here(lead), state: :in_progress, stage: stage.key},
          now
        )
    end
  end

  defp move(scope, :more_info, lead, message, params, now) do
    task = %{
      "title" => "Reply to #{who(message)}: more information",
      "team_id" => lead.job.team_id,
      "lead_id" => lead.id,
      "primary_user_id" => lead.owner_user_id,
      "due_on" => Leads.blank(params["due_on"])
    }

    with {:ok, _task} <- Core.Tasks.create(scope, task, now), do: sheet(scope, lead, now)
  end

  defp move(scope, :rejection, lead, _message, params, now),
    do: Act.run(scope, :finish, lead.id, %{from: params["from"], outcome: :rejected}, now)

  defp move(scope, :position_closed, lead, _message, params, now),
    do: Act.run(scope, :finish, lead.id, %{from: params["from"], outcome: :position_closed}, now)

  defp move(scope, :unsubscribe, lead, message, _params, now) do
    with {:ok, contact} <- sender(message),
         {:ok, updated} <- ContactStore.update(contact, %{is_do_not_contact: true}) do
      :ok = Core.Contacts.audit_change(scope, contact, updated, now)
      sheet(scope, lead, now)
    end
  end

  defp move(scope, :bounce, lead, message, _params, now) do
    case bounced(message) do
      [] ->
        Leads.invalid("class", "names no handle we hold: nothing to mark invalid")

      handles ->
        Enum.each(handles, fn h -> {:ok, _invalid} = ContactStore.invalidate_handle(h) end)
        sheet(scope, lead, now)
    end
  end

  defp move(scope, _interview_or_general, lead, _message, _params, now),
    do: sheet(scope, lead, now)

  defp sheet(_scope, nil, _now), do: {:ok, nil}
  defp sheet(scope, lead, now), do: Leads.get(scope, lead.id, now)

  defp classified(_scope, nil, _message, _class, _now), do: :ok

  defp classified(scope, lead, message, class, now) do
    lead = Data.Leads.reload(lead)

    _event =
      Ledger.record(
        scope,
        lead,
        :classified,
        %{message_id: message.id, to_label: words(class), visibility: :staff},
        now
      )

    :ok
  end

  # The version's first `screening` stage, when the lead is In progress before it.
  defp screening(%{state: :in_progress, stage: %{} = current} = lead) do
    stages = lead.pipeline_version.stages
    target = Enum.find(stages, &(kind(&1) == :screening))
    at = &Enum.find_index(stages, fn s -> s.id == &1.id end)

    if target && at.(current) < at.(target), do: target
  end

  defp screening(_lead), do: nil

  defp kind(%{kind: :custom, anchor_kind: anchor}), do: anchor
  defp kind(%{kind: kind}), do: kind

  defp here(lead), do: %{state: lead.state, stage: lead.stage && lead.stage.key}

  defp who(%{from_contact: %{name: name}}), do: name
  defp who(m), do: Notices.who(m)

  defp sender(%{from_kind: :contact, from_contact_id: id, organisation_id: org})
       when is_binary(id),
       do: {:ok, ContactStore.get(org, id)}

  defp sender(_message),
    do: Leads.invalid("class", "needs the sender as a contact: mark them first")

  # A bounce names the address it could not reach: the message's own
  # sender's or recipients', or its parent's recipients — whichever are a
  # contact's email handles.
  defp bounced(message) do
    parent =
      message.parent_message_id &&
        Store.message(message.organisation_id, message.parent_message_id)

    [message.from_text, message.to_text, parent && parent.to_text]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Regex.scan(~r/[^\s<>,"]+@[^\s<>,"]+/, &1))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> then(&ContactStore.email_handles(message.organisation_id, &1))
  end
end
