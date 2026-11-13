defmodule Core.Conversations do
  @moduledoc """
  Conversations (AQ-06 P6.1–P6.3): read, and shaped (§11.6). The writes
  are `Core.Conversations.Messages` (by hand), `Core.Conversations.Inbox`
  (an `.eml`), `Core.Ingest.Conversation` (the extension's capture),
  `Core.Conversations.Triage` and `Core.Conversations.Classify`; what every
  write records on a lead is `Core.Conversations.Record`.

  **One team each** (QP6-5); seen through its leads by P4a's rules, a
  triage item by its team (`Core.Access.Conversations`). An unseen
  conversation is `:not_found`. **The customer's view is cut here**
  (QP6-21): only when the lead's team has `customer_sees_conversations`
  on, never a staff note, staff by first name only when the team shows
  names, and no contact's handle (a header's address) in what they read.
  """

  alias Core.Access
  alias Core.Contacts
  alias Core.Conversations.Tree
  alias Core.Leads
  alias Core.Media
  alias Core.Tasks.Person
  alias Data.Conversations, as: Store
  alias Data.Conversations.{Conversation, Message}
  alias Data.Scope
  alias Data.Teams

  @doc "The conversation behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Conversation.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Conversation{} = c <-
           Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:conversation, subject(c)}),
         do: {:ok, c}
  end

  @doc "What `Core.Access.Conversations` decides on: the conversation's team, customer, setting and leads."
  @spec subject(Conversation.t()) :: map()
  def subject(%Conversation{} = c) do
    %{
      organisation_id: c.organisation_id,
      team_id: c.team_id,
      customer_id: c.customer_id,
      customer_sees: Teams.get_settings(c.team_id).customer_sees_conversations,
      leads: Enum.map(c.links, &Leads.subject(&1.lead))
    }
  end

  @doc "A message's subject, with its conversation's."
  @spec message_subject(Message.t(), map()) :: map()
  def message_subject(%Message{} = m, conversation_subject) do
    %{
      author_user_id: m.created_by_user_id,
      captured_via: m.captured_via,
      is_internal: m.is_internal,
      conversation: conversation_subject
    }
  end

  @doc "`GET /leads/:id/conversations`: the lead's conversations as the caller sees them, each with its tree."
  @spec for_lead(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def for_lead(%Scope{} = scope, lead_id) do
    with {:ok, lead} <- Leads.fetch(scope, :read, lead_id), do: {:ok, of_lead(scope, lead)}
  end

  @doc "The conversations of a lead the caller may read: the console's, or the customer's when the team allows."
  @spec of_lead(Scope.t(), map()) :: [map()]
  def of_lead(%Scope{} = scope, lead) do
    lead.id
    |> Store.for_lead()
    |> views(scope)
  end

  @doc "`GET /conversations/:id`: one conversation."
  @spec get(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, c} <- fetch(scope, :read, id), do: {:ok, view(scope, c)}
  end

  @doc "The conversations a contact takes part in that the caller may read (the contact's page)."
  @spec for_contact(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def for_contact(%Scope{} = scope, contact_id) do
    with {:ok, contact} <- Contacts.fetch(scope, :read, contact_id),
         do: {:ok, contact.id |> Store.for_contact() |> views(scope)}
  end

  defp views(conversations, scope) do
    readable =
      Enum.filter(conversations, &Access.can?(scope, :read, {:conversation, subject(&1)}))

    messages = Store.messages(Enum.map(readable, & &1.id)) |> Enum.group_by(& &1.conversation_id)
    Enum.map(readable, &view(scope, &1, Map.get(messages, &1.id, [])))
  end

  # ── The shapes (§11.6) ──────────────────────────────────────────────────────

  @doc "**conversation**, as `scope` sees it, with its tree."
  @spec view(Scope.t(), Conversation.t(), [Message.t()] | nil) :: map()
  def view(%Scope{} = scope, %Conversation{} = c, messages \\ nil) do
    messages = messages || Store.messages([c.id])
    csub = subject(c)
    customer? = Scope.customer?(scope)
    ctx = context(scope, c, csub)

    shown = if customer?, do: Enum.reject(messages, & &1.is_internal), else: messages
    {roots, gaps} = Tree.build(shown, &message_node(ctx, &1, &2, &3))

    %{
      id: c.id,
      # The customer never sees a team's name (AQ-04A QP4a-14).
      team: if(customer?, do: nil, else: %{id: c.team.id, name: c.team.name}),
      platform: c.platform,
      subject: c.subject,
      channel: c.channel && %{id: c.channel.id, label: c.channel.label || c.channel.handle},
      participants: Enum.map(c.participants, &Contacts.ref(&1.contact)),
      leads: leads(scope, c),
      last_message_at: c.last_message_at,
      ignored_at: if(customer?, do: nil, else: c.ignored_at),
      messages: roots,
      gaps: gaps
    }
  end

  defp leads(scope, c) do
    for link <- c.links,
        Access.can?(scope, :read, {:lead, Leads.subject(link.lead)}) do
      %{
        id: link.lead.id,
        title: lead_title(link.lead),
        match_method: link.match_method,
        confidence: link.confidence
      }
    end
  end

  @doc ~S|A lead as a conversation names it: "Backend Developer · Bamboo Invest".|
  @spec lead_title(map()) :: String.t()
  def lead_title(%{job: %{title: title, company: %{name: name}}}), do: title <> " · " <> name
  def lead_title(%{job: %{title: title}}), do: title

  defp context(scope, c, csub) do
    customer = c.customer

    %{
      scope: scope,
      csub: csub,
      customer: customer,
      customer?: Scope.customer?(scope),
      names?: Scope.customer?(scope) and Teams.get_settings(c.team_id).customer_sees_staff_names,
      write?: Access.can?(scope, :write, {:conversation, csub})
    }
  end

  @doc "One message of `c` as `scope` sees it, without its children (a triage item's first, a classify's answer)."
  @spec node(Scope.t(), Conversation.t(), Message.t()) :: map()
  def node(%Scope{} = scope, %Conversation{} = c, %Message{} = m) do
    held = c.id |> Store.rfc_ids() |> MapSet.new()
    message_node(context(scope, c, subject(c)), m, [], Tree.gap?(m, held))
  end

  @doc "A message as a node of the tree (§11.6's **message**), `children` and `parent_missing` given."
  @spec message_node(map(), Message.t(), [map()], boolean()) :: map()
  def message_node(ctx, %Message{} = m, children, parent_missing) do
    deleted? = not is_nil(m.deleted_at)

    %{
      id: m.id,
      direction: m.direction,
      is_internal: m.is_internal,
      from: from(ctx, m),
      to_text: if(ctx.customer?, do: names_only(m.to_text), else: m.to_text),
      sent_at: m.sent_at,
      body_text: m.body_text,
      body_html: m.body_html,
      parent_id: m.parent_message_id,
      captured_via: captured_via(ctx, m),
      invite: invite(ctx, m),
      classification: if(ctx.customer?, do: nil, else: m.classification),
      attachments: attachments(m),
      deleted: deleted?,
      parent_missing: parent_missing,
      can: can(ctx, m, deleted?),
      children: children
    }
  end

  defp can(ctx, m, deleted?) do
    msub = message_subject(m, ctx.csub)
    typed? = not deleted? and m.captured_via == :manual
    may = &Access.can?(ctx.scope, &1, {:message, msub})

    %{
      edit: typed? and may.(:edit),
      delete: typed? and may.(:delete),
      classify: not deleted? and m.direction == :in and may.(:classify),
      reply: not deleted? and not m.is_internal and ctx.write?
    }
  end

  # AQ-09 §11.4: the meeting an invitation in this mail proposed (the
  # customer never sees a proposed one).
  defp invite(ctx, %Message{invites: [_ | _] = meetings}) do
    case Enum.reject(meetings, &(ctx.customer? and &1.status == :proposed)) do
      [m | _rest] -> %{meeting_id: m.id}
      [] -> nil
    end
  end

  defp invite(_ctx, _message), do: nil

  # A press in the extension is the person's, as anywhere the customer reads.
  defp captured_via(%{customer?: true}, %{captured_via: :extension}), do: :manual
  defp captured_via(_ctx, m), do: m.captured_via

  defp from(_ctx, %Message{from_kind: :contact} = m),
    do: %{kind: :contact, contact: Contacts.ref(m.from_contact), person: nil, text: nil}

  defp from(%{customer?: true} = ctx, %Message{from_kind: :user} = m),
    do: %{
      kind: :user,
      contact: nil,
      person: Person.for_customer(m.from_user, ctx.customer, ctx.names?),
      text: nil
    }

  defp from(_ctx, %Message{from_kind: :user} = m),
    do: %{kind: :user, contact: nil, person: Person.view(m.from_user), text: nil}

  defp from(ctx, %Message{from_kind: :customer}) do
    person =
      ctx.customer &&
        %{user_id: ctx.customer.user_id, name: ctx.customer.display_name, photo_url: nil}

    %{kind: :customer, contact: nil, person: person, text: nil}
  end

  defp from(ctx, %Message{from_kind: :text} = m) do
    text = if ctx.customer?, do: names_only(m.from_text), else: m.from_text
    %{kind: :text, contact: nil, person: nil, text: text}
  end

  defp attachments(%Message{attachments: links}) when is_list(links) do
    links
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn mm ->
      %{
        media_id: mm.media_id,
        filename: mm.filename || mm.media.original_filename,
        content_type: mm.media.content_type,
        url: Media.link(mm.media_id)
      }
    end)
  end

  defp attachments(_message), do: []

  @doc ~S"""
  A header's people without their addresses, for the customer (no contact's
  handle reaches the portal).

      iex> Core.Conversations.names_only("Mei Chen <mei.chen@juniperedge.example>, bob@example.com")
      "Mei Chen"
      iex> Core.Conversations.names_only(nil)
      nil
  """
  @spec names_only(String.t() | nil) :: String.t() | nil
  def names_only(nil), do: nil

  def names_only(text) do
    text
    |> String.split(",")
    |> Enum.map(fn part ->
      part |> String.replace(~r/<[^>]*>/, "") |> String.replace(~r/\S+@\S+/, "") |> String.trim()
    end)
    |> Enum.map(&String.trim(&1, "\""))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end
end
