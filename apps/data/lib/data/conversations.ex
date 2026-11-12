defmodule Data.Conversations do
  @moduledoc """
  Conversations, their links, participants, messages and files (AQ-06
  §5.2). Storage only: who reads or writes one is `Core.Access`'s, the
  threading, matching and triage `Core.Conversations`'. Every read is the
  organisation's; **triage is a query** (QP6-9): a team's conversations
  linked to no lead and not ignored.
  """

  import Ecto.Query, warn: false

  alias Data.Conversations.{Conversation, ConversationLead, Message, MessageMedia, Participant}
  alias Data.Repo

  @person [person: :photo]

  @doc "What a conversation read carries: its team, channel, customer, links (with their leads) and participants."
  def preload do
    [
      :team,
      :channel,
      :customer,
      links: [lead: Data.Leads.base_preload()],
      participants: [contact: Data.Contacts.preload()]
    ]
  end

  @message_preload [
    :from_contact,
    from_user: @person,
    attachments: [:media]
  ]

  # ── Conversations ───────────────────────────────────────────────────────────

  @doc "A conversation of the organisation, with what a read carries; `nil` otherwise."
  @spec get(binary(), term()) :: Conversation.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Conversation
        |> Repo.get_by(id: uuid, organisation_id: organisation_id)
        |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The conversation again, fresh."
  @spec reload(Conversation.t()) :: Conversation.t()
  def reload(%Conversation{} = c), do: get(c.organisation_id, c.id)

  @doc "The conversations linked to a lead, newest message first."
  @spec for_lead(binary()) :: [Conversation.t()]
  def for_lead(lead_id) do
    from(c in Conversation,
      join: l in ConversationLead,
      on: l.conversation_id == c.id,
      where: l.lead_id == ^lead_id,
      order_by: [desc_nulls_last: c.last_message_at, desc: c.id]
    )
    |> load_all()
  end

  @doc "The conversations a contact takes part in, newest message first."
  @spec for_contact(binary()) :: [Conversation.t()]
  def for_contact(contact_id) do
    from(c in Conversation,
      join: p in Participant,
      on: p.conversation_id == c.id,
      where: p.contact_id == ^contact_id,
      order_by: [desc_nulls_last: c.last_message_at, desc: c.id]
    )
    |> load_all()
  end

  @doc "A team's triage (QP6-9): linked to no lead, not ignored, newest first."
  @spec triage(binary()) :: [Conversation.t()]
  def triage(team_id) do
    linked = from(l in ConversationLead, select: l.conversation_id)

    from(c in Conversation,
      where: c.team_id == ^team_id and is_nil(c.ignored_at) and c.id not in subquery(linked),
      order_by: [desc_nulls_last: c.last_message_at, desc: c.id],
      limit: 200
    )
    |> load_all()
  end

  @doc "The team's conversation on a provider's thread, or `nil`."
  @spec by_thread(binary(), atom(), String.t() | nil) :: Conversation.t() | nil
  def by_thread(_team_id, _platform, nil), do: nil

  def by_thread(team_id, platform, thread_id) do
    Conversation
    |> Repo.get_by(team_id: team_id, platform: platform, external_thread_id: thread_id)
    |> load()
  end

  @doc """
  A team's email conversation with this base subject (no `Re:`), holding
  `contact_id`: the last resort for a reply with no threading headers.
  """
  @spec by_subject(binary(), String.t(), binary()) :: Conversation.t() | nil
  def by_subject(team_id, subject, contact_id) do
    from(c in Conversation,
      join: p in Participant,
      on: p.conversation_id == c.id,
      where:
        c.team_id == ^team_id and c.platform == :email and p.contact_id == ^contact_id and
          fragment("lower(btrim(?))", c.subject) == ^subject,
      order_by: [desc_nulls_last: c.last_message_at],
      limit: 1
    )
    |> load_all()
    |> List.first()
  end

  @doc "How many conversations a lead has per platform: `%{platform => n}`."
  @spec platform_counts(binary()) :: %{atom() => non_neg_integer()}
  def platform_counts(lead_id) do
    from(c in Conversation,
      join: l in ConversationLead,
      on: l.conversation_id == c.id,
      where: l.lead_id == ^lead_id,
      group_by: c.platform,
      select: {c.platform, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @spec create(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, c} <- %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(c)}
  end

  @spec update(Conversation.t(), map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def update(%Conversation{} = c, attrs) do
    with {:ok, updated} <- c |> Conversation.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "Moves `last_message_at` forward to `at` (never back)."
  @spec touch(binary(), DateTime.t()) :: :ok
  def touch(conversation_id, %DateTime{} = at) do
    from(c in Conversation,
      where: c.id == ^conversation_id and (is_nil(c.last_message_at) or c.last_message_at < ^at)
    )
    |> Repo.update_all(set: [last_message_at: at])

    :ok
  end

  @doc "A link to a lead; an existing link is kept as it was."
  @spec link(map()) :: {:ok, :linked | :kept}
  def link(attrs) do
    {count, _rows} =
      Repo.insert_all(
        ConversationLead,
        [
          Map.take(attrs, [
            :conversation_id,
            :lead_id,
            :match_method,
            :confidence,
            :linked_by_user_id
          ])
        ],
        on_conflict: :nothing,
        conflict_target: [:conversation_id, :lead_id]
      )

    {:ok, if(count == 1, do: :linked, else: :kept)}
  end

  @doc "The lead ids a conversation is linked to."
  @spec lead_ids(binary()) :: [binary()]
  def lead_ids(conversation_id) do
    Repo.all(
      from(l in ConversationLead, where: l.conversation_id == ^conversation_id, select: l.lead_id)
    )
  end

  @doc "A contact in a conversation; already there is fine."
  @spec add_participant(binary(), binary() | nil) :: :ok
  def add_participant(_conversation_id, nil), do: :ok

  def add_participant(conversation_id, contact_id) do
    Repo.insert_all(Participant, [%{conversation_id: conversation_id, contact_id: contact_id}],
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :contact_id]
    )

    :ok
  end

  # ── Messages ────────────────────────────────────────────────────────────────

  @doc "The messages of conversations, oldest first, with their authors and files."
  @spec messages([binary()]) :: [Message.t()]
  def messages([]), do: []

  def messages(conversation_ids) do
    from(m in Message,
      where: m.conversation_id in ^conversation_ids,
      order_by: [asc: m.sent_at, asc: m.id],
      preload: ^@message_preload
    )
    |> Repo.all()
  end

  @doc "A message of the organisation, with its author and files; `nil` otherwise."
  @spec message(binary(), term()) :: Message.t() | nil
  def message(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Message
        |> Repo.get_by(id: uuid, organisation_id: organisation_id)
        |> then(&(&1 && Repo.preload(&1, @message_preload)))

      :error ->
        nil
    end
  end

  def message(_organisation_id, _id), do: nil

  @doc "The organisation's message with this idempotency key, or `nil`."
  @spec message_by_key(binary(), String.t()) :: Message.t() | nil
  def message_by_key(organisation_id, key),
    do: Repo.get_by(Message, organisation_id: organisation_id, idempotency_key: key)

  @doc "Which of `keys` the organisation holds already."
  @spec held_keys(binary(), [String.t()]) :: [String.t()]
  def held_keys(_organisation_id, []), do: []

  def held_keys(organisation_id, keys) do
    from(m in Message,
      where: m.organisation_id == ^organisation_id and m.idempotency_key in ^keys,
      select: m.idempotency_key
    )
    |> Repo.all()
  end

  @doc "The team's messages with these `Message-ID`s, each with its conversation id."
  @spec by_rfc_ids(binary(), binary(), [String.t()]) :: [Message.t()]
  def by_rfc_ids(_organisation_id, _team_id, []), do: []

  def by_rfc_ids(organisation_id, team_id, rfc_ids) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.organisation_id == ^organisation_id and c.team_id == ^team_id and
          m.rfc_message_id in ^rfc_ids
    )
    |> Repo.all()
  end

  @doc """
  The team's messages waiting for `rfc_id`: their `In-Reply-To` is it, or
  their `References` hold it — the children an arriving parent re-links.
  """
  @spec waiting_for(binary(), binary(), String.t()) :: [Message.t()]
  def waiting_for(organisation_id, team_id, rfc_id) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.organisation_id == ^organisation_id and c.team_id == ^team_id and
          (m.in_reply_to == ^rfc_id or ^rfc_id in m.references)
    )
    |> Repo.all()
  end

  @doc "The `Message-ID`s a conversation holds."
  @spec rfc_ids(binary()) :: [String.t()]
  def rfc_ids(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and not is_nil(m.rfc_message_id),
      select: m.rfc_message_id
    )
    |> Repo.all()
  end

  @spec insert_message(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def insert_message(attrs), do: %Message{} |> Message.changeset(attrs) |> Repo.insert()

  @spec update_message(Ecto.Changeset.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def update_message(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)

  @doc "A message's parent set (re-linking a child when its parent arrives)."
  @spec set_parent(binary(), binary() | nil) :: :ok
  def set_parent(message_id, parent_id) do
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(set: [parent_message_id: parent_id])

    :ok
  end

  @doc "Messages moved to another conversation (a child that came first, joining its parent's)."
  @spec move_messages([binary()], binary()) :: :ok
  def move_messages([], _conversation_id), do: :ok

  def move_messages(ids, conversation_id) do
    from(m in Message, where: m.id in ^ids)
    |> Repo.update_all(set: [conversation_id: conversation_id])

    :ok
  end

  @doc "Senders written as text whose address is one of `addresses` become `contact_id`."
  @spec attribute_senders(binary(), [String.t()], binary()) :: non_neg_integer()
  def attribute_senders(_conversation_id, [], _contact_id), do: 0

  def attribute_senders(conversation_id, addresses, contact_id) do
    patterns = Enum.map(addresses, &("%" <> Data.Companies.escape_like(&1) <> "%"))

    {count, _rows} =
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and m.from_kind == :text and
            fragment("lower(?) LIKE ANY(?)", m.from_text, ^patterns)
      )
      |> Repo.update_all(set: [from_kind: :contact, from_contact_id: contact_id])

    count
  end

  @spec add_media(map()) :: {:ok, MessageMedia.t()} | {:error, Ecto.Changeset.t()}
  def add_media(attrs), do: %MessageMedia{} |> MessageMedia.changeset(attrs) |> Repo.insert()

  @doc """
  The customers `team_id` serves whose email, or an email channel's
  address, is `address` (lowercased): who an `.eml` is from or to.
  """
  @spec customers_at(binary(), String.t() | nil) :: [binary()]
  def customers_at(_team_id, nil), do: []

  def customers_at(team_id, address) do
    channel =
      from(ch in Data.Customers.Channel,
        where: ch.kind == :email and ch.handle_normalized == ^address and is_nil(ch.archived_at),
        select: ch.customer_id
      )

    from(c in Data.Customers.Customer,
      join: ct in Data.Customers.CustomerTeam,
      on: ct.customer_id == c.id and ct.team_id == ^team_id,
      where: c.email == ^address or c.id in subquery(channel),
      select: c.id,
      distinct: true
    )
    |> Repo.all()
  end

  @doc "Deletes a conversation left with no message (a child that moved to its parent's)."
  @spec delete_if_empty(binary()) :: :ok
  def delete_if_empty(conversation_id) do
    held = from(m in Message, where: m.conversation_id == ^conversation_id, select: count())

    if Repo.one(held) == 0,
      do: Repo.delete_all(from(c in Conversation, where: c.id == ^conversation_id))

    :ok
  end

  # ── Retention (AQ-06 §10) ───────────────────────────────────────────────────

  @doc "The conversations linked to this lead and to no other: what its purge takes."
  @spec held_only_by(binary()) :: [binary()]
  def held_only_by(lead_id) do
    mine = from(l in ConversationLead, where: l.lead_id == ^lead_id, select: l.conversation_id)

    shared =
      from(l in ConversationLead,
        where: l.conversation_id in subquery(mine) and l.lead_id != ^lead_id,
        select: l.conversation_id
      )

    from(c in Conversation,
      where: c.id in subquery(mine) and c.id not in subquery(shared),
      select: c.id
    )
    |> Repo.all()
  end

  @doc "The files of conversations' messages: their attachments and the `.eml`s they came from."
  @spec media_of([binary()]) :: [Data.Files.Media.t()]
  def media_of([]), do: []

  def media_of(conversation_ids) do
    messages = from(m in Message, where: m.conversation_id in ^conversation_ids, select: m.id)

    attached =
      from(mm in MessageMedia, where: mm.message_id in subquery(messages), select: mm.media_id)

    sources =
      from(m in Message,
        where: m.conversation_id in ^conversation_ids and not is_nil(m.source_media_id),
        select: m.source_media_id
      )

    from(f in Data.Files.Media,
      where: f.id in subquery(attached) or f.id in subquery(sources)
    )
    |> Repo.all()
  end

  @doc "Deletes conversations; their messages, links, participants and file links cascade."
  @spec delete_all([binary()]) :: non_neg_integer()
  def delete_all([]), do: 0

  def delete_all(ids) do
    {count, _rows} = Repo.delete_all(from(c in Conversation, where: c.id in ^ids))
    count
  end

  # ── Loading ─────────────────────────────────────────────────────────────────

  defp load(nil), do: nil
  defp load(c), do: c |> Repo.preload(preload(), force: true) |> fill()

  defp load_all(query), do: query |> Repo.all() |> Repo.preload(preload()) |> Enum.map(&fill/1)

  defp fill(%Conversation{links: links} = c) do
    %{
      c
      | links:
          Enum.map(links, fn l ->
            %{l | lead: Data.Leads.fill(l.lead)}
          end)
    }
  end
end
