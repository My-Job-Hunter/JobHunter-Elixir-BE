defmodule Core.Conversations.Messages do
  @moduledoc """
  *Log message* (AQ-06 §7.1, §11.6): a message typed by hand — inbound or
  outbound, by a contact, a staff member, the customer or a name as
  written, when, with **Replies to** (a message of the conversation),
  which makes the tree, so a hand-copied thread has the original's shape.
  A staff note (`is_internal`) is outbound, by the caller, never shown to
  the customer and writes no event. *Draft reply → Copy* records the same
  way (QP6-13).

  `POST /messages {lead_id | conversation_id | team_id, …}`: with only
  `lead_id` a new conversation on that lead (by hand, sure); with
  `team_id` alone a new one in that team's triage. Whoever may change the
  lead writes (`:converse`), any member on triage.

  **Hand-typed messages are edited or deleted** (QP6-8) by their author or
  a team lead, audited; a deleted one is a tombstone that keeps its place.
  Captured and `.eml` messages never ("Captured messages can't be
  edited.").
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Conversations
  alias Core.Conversations.Record
  alias Core.Leads
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: Store
  alias Data.Conversations.Message
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @audited ~w(conversation_id direction is_internal from_kind from_contact_id from_user_id
              from_text sent_at body_text parent_message_id deleted_at)a
  @skew 120

  @doc "`POST /messages`: answers the **conversation** with its tree."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, target} <- target(scope, params),
         {:ok, fields} <- fields(scope, target, params, now) do
      Write.commit(fn -> insert(scope, target, fields, now) end)
      |> answer(scope)
    end
  end

  # Where the message goes: a conversation, a lead's new one, a team's new one.
  defp target(scope, %{"conversation_id" => id}) when is_binary(id) and id != "" do
    with {:ok, c} <- Conversations.fetch(scope, :write, id), do: {:ok, {:conversation, c}}
  end

  defp target(scope, %{"lead_id" => id}) when is_binary(id) and id != "" do
    with {:ok, lead} <- Leads.fetch(scope, :converse, id), do: {:ok, {:lead, lead}}
  end

  defp target(scope, %{"team_id" => id}) when is_binary(id) and id != "" do
    with {:ok, team} <- Core.Jobs.team(scope, %{"team_id" => id}), do: {:ok, {:team, team}}
  end

  defp target(_scope, _params), do: {:error, {:missing, [:lead_id]}}

  defp fields(scope, target, params, now) do
    internal? = params["is_internal"] in [true, "true"]

    with {:ok, direction} <- direction(params["direction"], internal?),
         {:ok, from} <- from(scope, target, params["from"], internal?),
         {:ok, sent_at} <- sent_at(params["sent_at"], now),
         {:ok, body} <- body(params["body_md"]),
         {:ok, parent_id} <- parent(scope, target, params["parent_message_id"]),
         {:ok, platform} <- platform(params["platform"]) do
      {:ok,
       Map.merge(from, %{
         direction: direction,
         is_internal: internal?,
         sent_at: sent_at,
         body_text: body,
         to_text: Leads.blank(params["to_text"]),
         parent_message_id: parent_id,
         platform: platform,
         subject: Leads.blank(params["subject"])
       })}
    end
  end

  defp insert(scope, target, fields, now) do
    with {:ok, c, linked} <- conversation(scope, target, fields, now),
         :ok <- customer_known(c, fields),
         {:ok, message} <-
           Store.insert_message(%{
             organisation_id: c.organisation_id,
             conversation_id: c.id,
             direction: fields.direction,
             is_internal: fields.is_internal,
             from_kind: fields.from_kind,
             from_contact_id: fields[:from_contact_id],
             from_user_id: fields[:from_user_id],
             from_text: fields[:from_text],
             to_text: fields.to_text,
             sent_at: fields.sent_at,
             body_text: fields.body_text,
             parent_message_id: fields.parent_message_id,
             captured_via: :manual,
             created_by_user_id: Scope.user_id(scope)
           }) do
      :ok = Store.add_participant(c.id, fields[:from_contact_id])
      {:ok, _audit} = Audit.record(scope, "created", message, after: snapshot(message), now: now)
      {:ok, c, [linked, Record.message(scope, c, message, now)]}
    end
  end

  # A lead's new conversation is linked by hand; a team's new one is triage.
  defp conversation(_scope, {:conversation, c}, _fields, _now), do: {:ok, c, []}

  defp conversation(scope, {:lead, lead}, fields, now) do
    with {:ok, c} <-
           Store.create(%{
             organisation_id: lead.organisation_id,
             team_id: lead.job.team_id,
             customer_id: lead.profile.customer_id,
             platform: fields.platform,
             subject: fields.subject
           }),
         {:ok, _how, events} <- Record.link(scope, c, lead, :by_hand, :sure, now) do
      {:ok, Store.reload(c), events}
    end
  end

  defp conversation(scope, {:team, team}, fields, _now) do
    with {:ok, c} <-
           Store.create(%{
             organisation_id: Scope.organisation_id(scope),
             team_id: team.id,
             platform: fields.platform,
             subject: fields.subject
           }),
         do: {:ok, c, []}
  end

  # The customer wrote it: the conversation must know whose.
  defp customer_known(%{customer_id: nil}, %{from_kind: :customer}),
    do:
      Leads.invalid("from.kind", "is customer, and this conversation's customer isn't known yet")

  defp customer_known(_c, _fields), do: :ok

  # ── Edit, delete (QP6-8) ────────────────────────────────────────────────────

  @doc "`PATCH /messages/:id {body_md?, sent_at?, parent_message_id?}`: hand-typed only, audited; answers the conversation."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, message, c} <- fetch(scope, :edit, id),
         :ok <- not_deleted(message),
         {:ok, attrs} <- edits(scope, message, c, params, now) do
      fn -> edited(scope, message, c, attrs, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp edited(scope, message, c, attrs, now) do
    with {:ok, edited} <-
           message
           |> Message.edit_changeset(Map.put(attrs, :edited_at, now))
           |> Store.update_message() do
      {:ok, _audit} =
        Audit.record(scope, "updated", edited,
          before: snapshot(message),
          after: snapshot(edited),
          now: now
        )

      {:ok, c, Record.changed(c)}
    end
  end

  @doc "`DELETE /messages/:id`: a tombstone (no body, its place kept), audited."
  @spec delete(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, message, c} <- fetch(scope, :delete, id),
         :ok <- not_deleted(message),
         {:ok, _c} <- Write.commit(fn -> deleted(scope, message, c, now) end),
         do: :ok
  end

  defp deleted(scope, message, c, now) do
    with {:ok, gone} <- message |> Message.delete_changeset(now) |> Store.update_message() do
      {:ok, _audit} = Audit.record(scope, "deleted", gone, before: snapshot(message), now: now)
      {:ok, c, Record.changed(c)}
    end
  end

  @doc "The message behind `id` and its conversation, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Message.t(), map()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Message{} = m <- Store.message(Scope.organisation_id(scope), id) || {:error, :not_found},
         c = Store.get(m.organisation_id, m.conversation_id),
         csub = Conversations.subject(c),
         :ok <- Access.why_not(scope, action, {:message, Conversations.message_subject(m, csub)}),
         do: {:ok, m, c}
  end

  defp not_deleted(%Message{deleted_at: nil}), do: :ok
  defp not_deleted(_m), do: Leads.invalid("id", "is a deleted message")

  defp edits(scope, message, c, params, now) do
    with {:ok, body} <- maybe(params, "body_md", &body/1),
         {:ok, sent_at} <- maybe(params, "sent_at", &sent_at(&1, now)),
         {:ok, parent} <-
           maybe(params, "parent_message_id", &parent(scope, {:conversation, c}, &1)),
         :ok <- no_cycle(message, parent) do
      {:ok,
       %{}
       |> put(:body_text, body)
       |> put(:sent_at, sent_at)
       |> then(
         &if(Map.has_key?(params, "parent_message_id"),
           do: Map.put(&1, :parent_message_id, parent),
           else: &1
         )
       )}
    end
  end

  defp maybe(params, key, fun) do
    if Map.has_key?(params, key), do: fun.(params[key]), else: {:ok, nil}
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  # *Replies to* never makes a message its own ancestor.
  defp no_cycle(_message, nil), do: :ok

  defp no_cycle(message, parent_id) do
    if ancestor?(message.id, parent_id, message.organisation_id, 0),
      do: Leads.invalid("parent_message_id", "is a reply to this message"),
      else: :ok
  end

  defp ancestor?(_id, _at, _org, depth) when depth > 200, do: true
  defp ancestor?(id, id, _org, _depth), do: true
  defp ancestor?(_id, nil, _org, _depth), do: false

  defp ancestor?(id, at, org, depth) do
    case Store.message(org, at) do
      nil -> false
      parent -> ancestor?(id, parent.parent_message_id, org, depth + 1)
    end
  end

  # ── The fields ──────────────────────────────────────────────────────────────

  defp direction(_value, true), do: {:ok, :out}
  defp direction(nil, _internal), do: {:error, {:missing, [:direction]}}

  defp direction(value, _internal) do
    if to_string(value) in Vocabulary.message_directions(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: Leads.invalid("direction", "is in or out")
  end

  # A note is the caller's own.
  defp from(scope, _target, _from, true),
    do: {:ok, %{from_kind: :user, from_user_id: Scope.user_id(scope)}}

  defp from(_scope, _target, nil, _internal), do: {:error, {:missing, [:from]}}

  defp from(scope, target, %{} = from, _internal) do
    from = Leads.stringify(from)

    case to_string(from["kind"]) do
      "contact" -> contact(scope, from["contact_id"])
      "user" -> user(scope, target, from["user_id"])
      "customer" -> {:ok, %{from_kind: :customer}}
      "text" -> text(from["text"])
      _other -> Leads.invalid("from.kind", "is contact, user, customer or text")
    end
  end

  defp from(_scope, _target, _from, _internal), do: Leads.invalid("from", "is {kind, …}")

  defp contact(_scope, nil), do: Leads.invalid("from.contact_id", "is required for a contact")

  defp contact(scope, id) do
    case ContactStore.get(Scope.organisation_id(scope), id) do
      nil -> Leads.invalid("from.contact_id", "is not a contact")
      %{merged_into_contact_id: nil} = c -> {:ok, %{from_kind: :contact, from_contact_id: c.id}}
      merged -> contact(scope, merged.merged_into_contact_id)
    end
  end

  defp user(scope, _target, nil),
    do: {:ok, %{from_kind: :user, from_user_id: Scope.user_id(scope)}}

  defp user(_scope, target, id) do
    team_id = team_id(target)

    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        if Teams.get_open_member(team_id, uuid),
          do: {:ok, %{from_kind: :user, from_user_id: uuid}},
          else: Leads.invalid("from.user_id", "isn't in this conversation's team")

      :error ->
        Leads.invalid("from.user_id", "isn't in this conversation's team")
    end
  end

  defp team_id({:conversation, c}), do: c.team_id
  defp team_id({:lead, lead}), do: lead.job.team_id
  defp team_id({:team, team}), do: team.id

  defp text(text) do
    case Leads.blank(text) do
      nil -> Leads.invalid("from.text", "says who wrote it")
      text -> {:ok, %{from_kind: :text, from_text: String.slice(String.trim(text), 0, 500)}}
    end
  end

  @doc false
  # When it was sent: a time, never later than now (a little clock skew allowed).
  def sent_at(nil, _now), do: {:error, {:missing, [:sent_at]}}

  def sent_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        if DateTime.diff(at, now) > @skew,
          do: Leads.invalid("sent_at", "can't be in the future"),
          else: {:ok, at}

      _not_a_time ->
        Leads.invalid("sent_at", "is not a time")
    end
  end

  def sent_at(_value, _now), do: Leads.invalid("sent_at", "is not a time")

  defp body(value) do
    case Leads.blank(value) do
      nil -> {:error, {:missing, [:body_md]}}
      body when byte_size(body) > 100_000 -> Leads.invalid("body_md", "is too long")
      body -> {:ok, String.trim(body)}
    end
  end

  # *Replies to*: a message of the same conversation (none for a new one).
  defp parent(_scope, _target, nil), do: {:ok, nil}
  defp parent(_scope, _target, ""), do: {:ok, nil}

  defp parent(scope, {:conversation, c}, id) do
    case Store.message(Scope.organisation_id(scope), id) do
      %{conversation_id: cid} = m when cid == c.id -> {:ok, m.id}
      _other -> Leads.invalid("parent_message_id", "is not a message of this conversation")
    end
  end

  defp parent(_scope, _new, _id),
    do: Leads.invalid("parent_message_id", "is not a message of this conversation")

  defp platform(nil), do: {:ok, :other}

  defp platform(value) do
    if to_string(value) in Vocabulary.platforms(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: Leads.invalid("platform", "is not a platform")
  end

  defp answer({:ok, c}, scope), do: {:ok, Conversations.view(scope, Store.reload(c))}
  defp answer(error, _scope), do: error

  defp snapshot(m), do: Audit.snapshot(m, @audited)
end
