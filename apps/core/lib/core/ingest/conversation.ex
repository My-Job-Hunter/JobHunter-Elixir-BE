defmodule Core.Ingest.Conversation do
  @moduledoc """
  The extension's *Capture conversation* (AQ-06 §9, §11.6, QP6-20):
  `POST /ext/v1/conversations/capture {request_id, team_id, profile_id,
  url, identity?, fields: {captured_at, page_kind: "thread", thread_id,
  other_profile_url, other_name, messages: [{external_id?, side:
  "them" | "us", sent_text, text}]}}` — a LinkedIn thread on a press, an
  Upwork room once linked — on P5's patterns: the acting profile and team,
  a `request_id`, `via: :extension` (its events are `actor_kind:
  extension` with the person, and activity).

  1. **The conversation** by the thread id (the provider's, a hint that
     joins, §7.1) in the team, or a new one about the acting profile's
     customer, on its channel when `identity` is that customer's.
  2. **The contact** by the other side's LinkedIn or Upwork handle
     (exact), or new (`source: extension`); a room with no profile link
     keeps the contact it already has.
  3. **Matching** a conversation on no lead: §7.2 rule 3 for the acting
     profile — the contact on exactly one open lead of this team for that
     profile links it (`sender_handle`, likely); else triage.
  4. **The messages**, deduped: by `(conversation, external_id)`; without
     one, by the same side and text sent within a day of one already here
     (never the raw `sent_text`: "Just now" changes). `side: "us"` is the
     customer when the page's account (`identity`) is the acting
     customer's channel, else the person pressing. `sent_text` is read by
     `Core.Ingest.Conversation.SentText`.

  Answers `{conversation_id, lead_id, lead_title, triage, added,
  link_path}`; a retry adds nothing (`added: 0`).
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Access
  alias Core.Contacts
  alias Core.Conversations
  alias Core.Conversations.{Notices, Record}
  alias Core.Extension.Context
  alias Core.Ingest.Conversation.SentText
  alias Core.Ingest.Extension.Pool
  alias Core.Leads
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Contacts.Handle
  alias Data.Conversations, as: Store
  alias Data.Conversations.Message
  alias Data.Repo
  alias Data.Scope

  @day 86_400
  @no_text "(No text captured.)"

  @spec capture(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def capture(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, _request_id} <- request_id(params["request_id"]),
         {:ok, fields} <- Pool.fields(params),
         {:ok, team} <- Core.Jobs.team(scope, params),
         {:ok, profile} <- Leads.profile(scope, params["profile_id"]),
         {:ok, site} <- site(params["url"]),
         {:ok, thread_id} <- thread_id(fields["thread_id"]),
         {:ok, rows} <- rows(fields["messages"]) do
      captured_at = captured_at(fields["captured_at"], now)
      zone = profile.customer.timezone || Core.Tasks.zone(scope)
      times = rows |> Enum.map(& &1.sent_text) |> SentText.place(captured_at, zone)
      us = us(scope, site, params["identity"], profile)
      page = %{site: site, thread_id: thread_id, fields: fields, us: us, profile: profile}

      Write.commit(fn -> land(scope, team, page, Enum.zip(rows, times), now) end)
      |> case do
        {:ok, {c, added}} -> {:ok, answer(scope, c, added)}
        error -> error
      end
    end
  end

  defp land(scope, team, page, rows, now) do
    {c, new?} = conversation(scope, team, page)

    with {:ok, contact} <- contact(scope, c, page, now) do
      :ok = Store.add_participant(c.id, contact && contact.id)
      {:ok, linked} = match(scope, c, contact, page.profile, now)
      inserted = Enum.flat_map(rows, &insert(scope, c, contact, page, &1))
      c = Store.reload(c)
      recorded = Enum.map(inserted, &Record.message(scope, c, &1, now))

      triage =
        if new? and c.links == [] and inserted != [],
          do: Notices.triage_new(scope, c, who(contact, page), page.profile),
          else: []

      {:ok, {c, length(inserted)}, [linked, recorded, triage]}
    end
  end

  defp conversation(scope, team, page) do
    case Store.by_thread(team.id, page.site, page.thread_id) do
      nil ->
        {:ok, c} =
          Store.create(%{
            organisation_id: Scope.organisation_id(scope),
            team_id: team.id,
            customer_id: page.profile.customer_id,
            channel_id: channel_id(page.us),
            platform: page.site,
            external_thread_id: page.thread_id
          })

        {c, true}

      c ->
        {c, false}
    end
  end

  # The other side: by its handle (exact), else the conversation's own
  # contact, else a new one named as the page names them.
  defp contact(scope, c, page, now) do
    org = Scope.organisation_id(scope)
    url = Utils.presence(page.fields["other_profile_url"])
    name = Utils.presence(page.fields["other_name"])
    handle = url && normalized(page.site, url)

    case found(org, c, page.site, handle) do
      nil -> new_contact(scope, page.site, {name, url, handle}, now)
      contact -> {:ok, contact}
    end
  end

  defp found(_org, c, _site, nil), do: first_participant(c)

  defp found(org, _c, site, handle),
    do: List.first(ContactStore.by_handles(org, [{site, handle}]))

  defp normalized(site, url) do
    case Handle.normalize(site, url) do
      {:ok, value} -> value
      {:error, _not_a_profile} -> nil
    end
  end

  defp first_participant(%{participants: [p | _rest]}), do: p.contact
  defp first_participant(_c), do: nil

  defp new_contact(_scope, _site, {nil, _url, nil}, _now), do: {:ok, nil}

  defp new_contact(scope, site, {name, url, handle}, now) do
    name = name || url
    handles = if handle, do: [%{"kind" => to_string(site), "value" => url}], else: []

    with {:ok, typed} <- Contacts.handles(handles) do
      case Contacts.insert(scope, %{}, String.slice(name, 0, 200), typed, now,
             source: "extension"
           ) do
        {:ok, {_how, contact}} ->
          {:ok, ContactStore.reload(contact)}

        {:error, {:contact_exists, %{contact_id: id}}} ->
          {:ok, ContactStore.get(Scope.organisation_id(scope), id)}

        error ->
          error
      end
    end
  end

  # §7.2 rule 3 for the acting profile, when nothing links it yet.
  defp match(_scope, %{links: [_ | _]}, _contact, _profile, _now), do: {:ok, []}
  defp match(_scope, _c, nil, _profile, _now), do: {:ok, []}

  defp match(scope, c, contact, profile, now) do
    case c.team_id
         |> ContactStore.open_leads_holding([contact.id], profile.id)
         |> Enum.map(&elem(&1, 0))
         |> Enum.uniq() do
      [one] ->
        lead = Data.Leads.get(c.organisation_id, one)

        case Record.link(scope, c, lead, :sender_handle, :likely, now) do
          {:ok, _how, events} -> {:ok, events}
          {:error, _another_customer} -> {:ok, []}
        end

      _none_or_several ->
        {:ok, []}
    end
  end

  # One row, unless it is here already.
  defp insert(scope, c, contact, page, {row, sent_at}) do
    direction = if row.side == "them", do: :in, else: :out
    text = row.text || @no_text
    key = key(c, row, direction, text, sent_at)

    if held?(c, key, row, direction, text, sent_at) do
      []
    else
      {:ok, m} =
        Store.insert_message(
          Map.merge(author(scope, direction, contact, page), %{
            organisation_id: c.organisation_id,
            conversation_id: c.id,
            direction: direction,
            sent_at: sent_at,
            body_text: text,
            captured_via: :extension,
            idempotency_key: key,
            created_by_user_id: Scope.user_id(scope)
          })
        )

      [m]
    end
  end

  defp author(_scope, :in, %{id: id}, _page), do: %{from_kind: :contact, from_contact_id: id}

  defp author(_scope, :in, nil, page),
    do: %{from_kind: :text, from_text: Utils.presence(page.fields["other_name"]) || "Them"}

  defp author(_scope, :out, _contact, %{us: {:customer, _channel}}), do: %{from_kind: :customer}

  defp author(scope, :out, _contact, _page),
    do: %{from_kind: :user, from_user_id: Scope.user_id(scope)}

  defp key(c, %{external_id: id}, _direction, _text, _at) when is_binary(id),
    do: "ext:#{c.id}:#{id}"

  defp key(c, _row, direction, text, sent_at) do
    hash = :crypto.hash(:sha256, "#{direction}|#{norm(text)}|#{DateTime.to_iso8601(sent_at)}")
    "ext:#{c.id}:h:" <> Base.encode16(hash, case: :lower)
  end

  defp held?(c, key, %{external_id: id}, _direction, _text, _at) when is_binary(id),
    do: Store.message_by_key(c.organisation_id, key) != nil

  defp held?(c, key, _row, direction, text, sent_at) do
    Store.message_by_key(c.organisation_id, key) != nil or
      Repo.exists?(
        from(m in Message,
          where:
            m.conversation_id == ^c.id and m.direction == ^direction and
              fragment("lower(regexp_replace(btrim(?), '\\s+', ' ', 'g'))", m.body_text) ==
                ^norm(text) and
              m.sent_at >= ^DateTime.add(sent_at, -@day, :second) and
              m.sent_at <= ^DateTime.add(sent_at, @day, :second)
        )
      )
  end

  defp norm(text), do: text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.downcase()

  # ── The page ────────────────────────────────────────────────────────────────

  # The page's account: the acting customer's channel, or not.
  defp us(scope, site, identity, profile) do
    case Context.channel(scope, site, identity) do
      {:channel, %{customer_id: id} = channel} when id == profile.customer_id ->
        {:customer, channel}

      _other ->
        :user
    end
  end

  defp channel_id({:customer, channel}), do: channel.id
  defp channel_id(_user), do: nil

  defp site(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) ->
        cond do
          String.ends_with?(host, "linkedin.com") -> {:ok, :linkedin}
          String.ends_with?(host, "upwork.com") -> {:ok, :upwork}
          true -> Leads.invalid("url", "is not a LinkedIn or Upwork thread")
        end

      _bad ->
        Leads.invalid("url", "is not a link")
    end
  end

  defp site(_url), do: {:error, {:missing, [:url]}}

  defp thread_id(id) do
    case Utils.presence(if(is_binary(id), do: id, else: nil)) do
      nil -> Leads.invalid("fields.thread_id", "is required")
      id -> {:ok, String.slice(id, 0, 300)}
    end
  end

  defp rows(list) when is_list(list) and list != [] do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, i}, {:ok, acc} ->
      row = Leads.stringify(row)

      if row["side"] in ["them", "us"] do
        {:cont,
         {:ok,
          [
            %{
              external_id: Utils.presence(to_string(row["external_id"] || "")),
              side: row["side"],
              sent_text: if(is_binary(row["sent_text"]), do: row["sent_text"]),
              text: if(is_binary(row["text"]), do: Utils.presence(row["text"]))
            }
            | acc
          ]}}
      else
        {:halt, Leads.invalid("fields.messages.#{i}.side", "is them or us")}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp rows(_other), do: Leads.invalid("fields.messages", "is a list of at least one message")

  defp captured_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> if DateTime.after?(at, now), do: now, else: at
      _bad -> now
    end
  end

  defp captured_at(_value, now), do: now

  defp request_id(id) do
    case is_binary(id) && Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      false -> {:error, {:missing, [:request_id]}}
      :error -> Leads.invalid("request_id", "is not a UUID")
    end
  end

  defp who(%{name: name}, _page), do: name
  defp who(nil, page), do: Utils.presence(page.fields["other_name"]) || "Someone"

  # ── The answer ──────────────────────────────────────────────────────────────

  defp answer(scope, c, added) do
    lead =
      c.links
      |> Enum.map(& &1.lead)
      |> Enum.find(&Access.can?(scope, :read, {:lead, Leads.subject(&1)}))

    %{
      conversation_id: c.id,
      lead_id: lead && lead.id,
      lead_title: lead && Conversations.lead_title(lead),
      triage: c.links == [],
      added: added,
      link_path:
        if(lead,
          do: "/leads/#{lead.id}?team=#{c.team_id}",
          else: "/triage?team=#{c.team_id}"
        )
    }
  end
end
