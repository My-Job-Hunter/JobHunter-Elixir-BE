defmodule Core.Conversations.Inbox do
  @moduledoc """
  An uploaded `.eml` landed (AQ-06 §7.1, §7.2): `POST /eml {media_id,
  team_id, lead_id?}` — the media an `eml` the caller uploaded.

  1. **Idempotency:** the `Message-ID` is the key (`rfc:<id>`; a hash of
     the bytes without one), so the same file twice adds nothing: answered
     with the conversation it is in, `added: 0, already: 1`.
  2. **Who wrote it:** the customer (their email, or an email channel of
     theirs) or a staff member is outbound; a contact by its email handle,
     else the name and address as written, inbound.
  3. **The conversation, headers first:** the one holding `In-Reply-To`'s
     message, else the last of `References` we hold (§13.3 rule 1); else
     the one where a child of this message is waiting for it; with
     `lead_id`, a new one on that lead; for a reply with no threading
     headers at all, the email conversation of the same subject with the
     same sender (the last resort); else a new one.
  4. **Matching** a conversation on no lead (rules 1–3): `lead_id` links
     by hand (sure); else the other side's contact on exactly one open
     lead of this team links (`sender_handle`, likely); several, or none,
     is triage (QP6-10).
  5. **The tree:** the parent by `Core.Conversations.Tree.parent/3`; any
     child that came first is moved here and re-parented, closing its gap.
  6. **Attachments** through P1's media, bytes sniffed (`Core.Media`); one
     off the allowlist is left out.

  One transaction holds it all, with the ledger rows, the notices and the
  audit row (`Core.Conversations.Record`).
  """

  alias Core.Audit
  alias Core.Conversations
  alias Core.Conversations.{Eml, Notices, Record, Tree}
  alias Core.Leads
  alias Core.Media
  alias Core.Storage
  alias Core.Tasks.Write
  alias Data.Accounts
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: Store
  alias Data.Conversations.Message
  alias Data.Scope
  alias Data.Teams

  @no_text "(This email had no text.)"

  @doc """
  `POST /eml`: `{:ok, {:created | :already, answer}}`, the answer
  `{conversation, landed: "lead" | "triage", leads: [{id, title}], added,
  already}`.
  """
  @spec eml(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), map()}} | {:error, term()}
  def eml(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- staff(scope),
         {:ok, team} <- Core.Jobs.team(scope, params),
         {:ok, lead} <- lead(scope, params["lead_id"], team),
         {:ok, media} <- media(scope, params["media_id"]),
         {:ok, mail} <- read(media) do
      key = key(mail, media)

      case Store.message_by_key(Scope.organisation_id(scope), key) do
        %Message{} = held -> {:ok, {:already, answer(scope, held.conversation_id, 0, 1)}}
        nil -> landed(scope, team, lead, media, mail, key, now)
      end
    end
  end

  defp landed(scope, team, lead, media, mail, key, now) do
    case Write.commit(fn -> land(scope, team, lead, media, mail, key, now) end) do
      {:ok, c} -> {:ok, {:created, answer(scope, c.id, 1, 0)}}
      error -> error
    end
  end

  defp staff(scope), do: if(Scope.customer?(scope), do: {:error, :not_found}, else: :ok)

  defp lead(_scope, id, _team) when id in [nil, ""], do: {:ok, nil}

  defp lead(scope, id, team) do
    with {:ok, lead} <- Leads.fetch(scope, :converse, id) do
      if lead.job.team_id == team.id,
        do: {:ok, lead},
        else: Leads.invalid("lead_id", "is in another team than team_id")
    end
  end

  defp media(_scope, nil), do: {:error, {:missing, [:media_id]}}
  defp media(scope, id), do: Media.own_uploaded(scope, id, :eml)

  defp read(media) do
    with {:ok, bytes} <- Storage.fetch(media.storage_key),
         {:ok, mail} <- Eml.parse(bytes) do
      {:ok, Map.put(mail, :sha, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))}
    else
      {:error, :unreadable} -> Leads.invalid("media_id", "is not an email we can read")
      _missing -> {:error, :not_found}
    end
  end

  defp key(%{message_id: id}, _media) when is_binary(id), do: "rfc:" <> id
  defp key(%{sha: sha}, _media), do: "eml:" <> sha

  # ── Landing ─────────────────────────────────────────────────────────────────

  defp land(scope, team, lead, media, mail, key, now) do
    org = Scope.organisation_id(scope)
    sender = sender(scope, team, lead, mail)
    {c, new?} = conversation(scope, team, lead, mail, sender)

    with {:ok, linked} <- links(scope, c, lead, sender, now),
         {:ok, message} <- insert(scope, c, media, mail, sender, key, now) do
      :ok = participants(c, sender)
      :ok = relink_children(org, team, c, mail.message_id)
      :ok = attach(scope, message, mail.attachments, now)
      {:ok, _audit} = Audit.record(scope, "created", message, after: snapshot(message), now: now)
      c = Store.reload(c)

      triage =
        if new? and c.links == [],
          do:
            Notices.triage_new(
              scope,
              c,
              Notices.who(Data.Repo.preload(message, :from_contact)),
              nil
            ),
          else: []

      {:ok, c, [linked, Record.message(scope, c, message, now), triage]}
    end
  end

  # Who wrote it, and which way it went.
  defp sender(scope, team, lead, %{from: {name, address}} = mail) do
    text = header(name, address)
    customers = Store.customers_at(team.id, address)
    lead_customer = lead && lead.profile.customer_id
    contact = contact_at(scope, address)

    cond do
      lead_customer && lead_customer in customers ->
        out(%{from_kind: :customer, from_text: text}, lead_customer, mail, scope)

      is_nil(lead) and length(customers) == 1 ->
        out(%{from_kind: :customer, from_text: text}, hd(customers), mail, scope)

      user = staff_at(team, address) ->
        out(
          %{from_kind: :user, from_user_id: user.id, from_text: text},
          lead_customer,
          mail,
          scope
        )

      contact ->
        %{
          direction: :in,
          from_kind: :contact,
          from_contact_id: contact.id,
          from_text: text,
          contacts: [contact.id],
          customer_id: lead_customer
        }

      true ->
        %{
          direction: :in,
          from_kind: :text,
          from_text: text,
          contacts: [],
          customer_id: lead_customer
        }
    end
  end

  # An outbound email's other side is its recipients that are contacts.
  defp out(fields, customer_id, mail, scope) do
    recipients =
      (mail.to ++ mail.cc)
      |> Enum.map(fn {_name, address} -> contact_at(scope, address) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    Map.merge(fields, %{
      direction: :out,
      contacts: Enum.uniq(recipients),
      customer_id: customer_id
    })
  end

  defp contact_at(_scope, nil), do: nil

  defp contact_at(scope, address) do
    case ContactStore.by_handles(Scope.organisation_id(scope), [{:email, address}]) do
      [contact | _rest] -> contact
      [] -> nil
    end
  end

  defp staff_at(team, address) do
    case address && Accounts.get_user_by_email(address) do
      %{id: id} = user -> if Teams.get_open_member(team.id, id), do: user
      _nobody -> nil
    end
  end

  defp header(nil, address), do: address
  defp header(name, nil), do: name
  defp header(name, address), do: "#{name} <#{address}>"

  # §7.1: headers first; then a child waiting for this one; then the lead;
  # then the subject with the same sender; else a new one.
  defp conversation(scope, team, lead, mail, sender) do
    org = Scope.organisation_id(scope)
    asked = Enum.reject([mail.in_reply_to | mail.references], &is_nil/1)
    hits = Store.by_rfc_ids(org, team.id, asked)

    found =
      by_headers(hits, mail) || waiting(org, team, mail) ||
        if(lead, do: nil, else: by_subject(team, mail, sender))

    case found do
      nil -> {new(scope, team, lead, mail, sender), true}
      id -> {Store.get(org, id), false}
    end
  end

  defp by_headers([], _mail), do: nil

  defp by_headers(hits, mail) do
    by_id = Map.new(hits, &{&1.rfc_message_id, &1.conversation_id})
    parent = Tree.parent(mail.in_reply_to, mail.references, MapSet.new(Map.keys(by_id)))
    Map.get(by_id, parent)
  end

  defp waiting(_org, _team, %{message_id: nil}), do: nil

  defp waiting(org, team, mail) do
    case Store.waiting_for(org, team.id, mail.message_id) do
      [child | _rest] -> child.conversation_id
      [] -> nil
    end
  end

  # The last resort, only for a reply with no threading headers at all.
  defp by_subject(_team, %{in_reply_to: id}, _sender) when not is_nil(id), do: nil
  defp by_subject(_team, %{references: [_ | _]}, _sender), do: nil
  defp by_subject(_team, _mail, %{contacts: []}), do: nil

  defp by_subject(team, %{subject: subject}, %{contacts: [contact | _rest]})
       when is_binary(subject) do
    base = Regex.replace(~r/^\s*((re|fw|fwd|aw)\s*:\s*)+/i, subject, "")

    if base != subject do
      case Store.by_subject(team.id, base |> String.trim() |> String.downcase(), contact) do
        nil -> nil
        c -> c.id
      end
    end
  end

  defp by_subject(_team, _mail, _sender), do: nil

  defp new(scope, team, lead, mail, sender) do
    {:ok, c} =
      Store.create(%{
        organisation_id: Scope.organisation_id(scope),
        team_id: team.id,
        customer_id: (lead && lead.profile.customer_id) || sender.customer_id,
        platform: :email,
        subject: mail.subject
      })

    c
  end

  # §7.2: by hand with `lead_id`; else one open lead holding the other side.
  defp links(scope, c, lead, sender, now) do
    cond do
      lead ->
        with {:ok, _how, events} <- Record.link(scope, c, lead, :by_hand, :sure, now),
             do: {:ok, events}

      c.links != [] ->
        {:ok, []}

      true ->
        case c.team_id
             |> ContactStore.open_leads_holding(sender.contacts, nil)
             |> Enum.map(&elem(&1, 0))
             |> Enum.uniq() do
          [one] -> likely(scope, c, one, now)
          _none_or_several -> {:ok, []}
        end
    end
  end

  defp likely(scope, c, lead_id, now) do
    case Data.Leads.get(c.organisation_id, lead_id) do
      nil ->
        {:ok, []}

      lead ->
        case Record.link(scope, c, lead, :sender_handle, :likely, now) do
          {:ok, _how, events} -> {:ok, events}
          {:error, _another_customer} -> {:ok, []}
        end
    end
  end

  defp insert(scope, c, media, mail, sender, key, now) do
    held = c.id |> Store.rfc_ids() |> MapSet.new()
    parent_rfc = Tree.parent(mail.in_reply_to, mail.references, held)

    parent_id =
      parent_rfc &&
        case Store.by_rfc_ids(c.organisation_id, c.team_id, [parent_rfc]) do
          [p | _rest] -> p.id
          [] -> nil
        end

    Store.insert_message(%{
      organisation_id: c.organisation_id,
      conversation_id: c.id,
      direction: sender.direction,
      from_kind: sender.from_kind,
      from_contact_id: sender[:from_contact_id],
      from_user_id: sender[:from_user_id],
      from_text: sender[:from_text],
      to_text: recipients(mail),
      sent_at: mail.sent_at || now,
      body_text: mail.text || @no_text,
      body_html: mail.html,
      parent_message_id: parent_id,
      rfc_message_id: mail.message_id,
      in_reply_to: mail.in_reply_to,
      references: mail.references,
      captured_via: :eml_upload,
      idempotency_key: key,
      source_media_id: media.id,
      created_by_user_id: Scope.user_id(scope)
    })
  end

  defp recipients(mail) do
    case mail.to ++ mail.cc do
      [] ->
        nil

      people ->
        people
        |> Enum.map_join(", ", fn {name, address} -> header(name, address) end)
        |> String.slice(0, 2000)
    end
  end

  defp participants(c, sender), do: Enum.each(sender.contacts, &Store.add_participant(c.id, &1))

  # A child that came before its parent: moved here when its own
  # conversation is triage, then given its parent by the rule.
  defp relink_children(_org, _team, _c, nil), do: :ok

  defp relink_children(org, team, c, rfc_id) do
    children = Store.waiting_for(org, team.id, rfc_id)

    movable =
      for child <- children,
          child.conversation_id == c.id or Store.lead_ids(child.conversation_id) == [],
          do: child

    for child <- movable, child.conversation_id != c.id do
      :ok = Store.move_messages([child.id], c.id)
      :ok = Store.delete_if_empty(child.conversation_id)
    end

    held = c.id |> Store.rfc_ids() |> MapSet.new()

    by_rfc =
      Map.new(Store.by_rfc_ids(org, team.id, MapSet.to_list(held)), &{&1.rfc_message_id, &1.id})

    for child <- movable do
      parent =
        Tree.parent(
          child.in_reply_to,
          child.references,
          MapSet.delete(held, child.rfc_message_id)
        )

      :ok = Store.set_parent(child.id, parent && by_rfc[parent])
    end

    :ok
  end

  defp attach(scope, message, attachments, now) do
    attachments
    |> Enum.with_index()
    |> Enum.each(fn {a, i} ->
      case Media.store_attachment(scope, a.bytes, a.filename, now) do
        {:ok, media} ->
          {:ok, _link} =
            Store.add_media(%{
              message_id: message.id,
              media_id: media.id,
              filename: a.filename,
              position: i
            })

        {:error, _off_the_list} ->
          :skipped
      end
    end)
  end

  # ── The answer ──────────────────────────────────────────────────────────────

  defp answer(scope, conversation_id, added, already) do
    c = Store.get(Scope.organisation_id(scope), conversation_id)
    view = Conversations.view(scope, c)

    %{
      conversation: view,
      landed: if(view.leads == [], do: "triage", else: "lead"),
      leads: Enum.map(view.leads, &%{id: &1.id, title: &1.title}),
      added: added,
      already: already
    }
  end

  defp snapshot(m),
    do:
      Audit.snapshot(m, [:conversation_id, :direction, :from_kind, :rfc_message_id, :captured_via])
end
