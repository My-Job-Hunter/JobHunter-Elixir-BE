defmodule Core.Conversations.Triage do
  @moduledoc """
  The team's triage (AQ-06 §7.3, QP6-9): **derived** — a conversation of
  the team linked to no lead and not ignored *is* a triage item; there is
  no table, and a link or an ignore is the only state. Every member of
  the team sees and sorts it; another team finds nothing.

  - **`GET /triage?team_id`**: newest first, each with its first message
    and its candidates — the open leads of the team holding one of its
    contacts (§7.2 rule 3: "Sender is a contact on *Backend Developer ·
    Bamboo Invest*").
  - **Link to lead** (`by_hand`, sure), whoever may change that lead.
  - ***Create job and lead***: P4a's `POST /leads` with a job body, at the
    pipeline's `inbound` stage (*Recruiter contact*), applied
    `recruiter_inbound` when the first message was sent, **in one
    transaction with the link** (`created_from_triage`).
  - ***Mark contact as recruiter***: the sender becomes a contact (or is
    one already), the messages written by that address are theirs, and
    with `lead_id` they are linked to that lead as its recruiter.
  - **Ignore** (and *Undo*: `unignore`).

  Each tells `team:<id>` `triage_changed` after commit.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Contacts
  alias Core.Contacts.LeadLinks
  alias Core.Conversations
  alias Core.Conversations.Record
  alias Core.Leads
  alias Core.Leads.{Sheet, Signals}
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: Store
  alias Data.Scope

  @doc "`GET /triage?team_id`: `{team, items: [triage item]}`."
  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params) do
    with :ok <- staff(scope),
         {:ok, team} <- Core.Jobs.team(scope, Leads.stringify(params)) do
      conversations = Store.triage(team.id)

      messages =
        conversations
        |> Enum.map(& &1.id)
        |> Store.messages()
        |> Enum.group_by(& &1.conversation_id)

      items =
        for c <- conversations do
          ms = Map.get(messages, c.id, [])
          item(scope, c, ms)
        end

      {:ok, %{team: %{id: team.id, name: team.name}, items: items}}
    end
  end

  defp item(scope, c, messages) do
    first = Enum.min_by(messages, &DateTime.to_unix(&1.sent_at, :microsecond), fn -> nil end)

    %{
      conversation: Conversations.view(scope, c, messages),
      first_message: first && Conversations.node(scope, c, first),
      candidates: candidates(scope, c, messages)
    }
  end

  @doc """
  A triage item's candidates (§7.2 rule 3): the open leads of its team
  holding one of its contacts, those the caller sees, each with why.
  """
  @spec candidates(Scope.t(), map(), list()) :: [map()]
  def candidates(scope, c, messages) do
    contacts =
      (Enum.map(c.participants, & &1.contact_id) ++
         Enum.map(messages, & &1.from_contact_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names = c.participants |> Map.new(&{&1.contact_id, &1.contact.name})

    for {lead_id, contact_id} <- ContactStore.open_leads_holding(c.team_id, contacts, nil),
        lead = Data.Leads.get(c.organisation_id, lead_id),
        lead && Access.can?(scope, :read, {:lead, Leads.subject(lead)}),
        uniq: true do
      who = Map.get(names, contact_id) || "Sender"

      %{
        lead:
          lead
          |> Sheet.row()
          |> Map.put(:job, %{
            id: lead.job.id,
            title: lead.job.title,
            company: lead.job.company && %{id: lead.job.company.id, name: lead.job.company.name}
          }),
        why: "#{who} is a contact on #{Conversations.lead_title(lead)}"
      }
    end
  end

  # ── The actions ─────────────────────────────────────────────────────────────

  @doc "`POST /conversations/:id/link {lead_id}`: by hand, sure. Answers the conversation."
  @spec link(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def link(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, c} <- Conversations.fetch(scope, :triage, id),
         {:ok, lead} <- lead(scope, params["lead_id"]) do
      fn -> linked(scope, c, lead, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp linked(scope, c, lead, now) do
    with {:ok, _how, events} <- Record.link(scope, c, lead, :by_hand, :sure, now),
         do: {:ok, c, events}
  end

  @doc "`POST /conversations/:id/ignore`: out of triage, audited. A linked conversation is not triage."
  @spec ignore(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def ignore(%Scope{} = scope, id, %DateTime{} = now),
    do: set_ignored(scope, id, %{ignored_at: now, ignored_by_user_id: Scope.user_id(scope)}, now)

  @doc "`POST /conversations/:id/unignore`: *Undo*, back in triage."
  @spec unignore(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def unignore(%Scope{} = scope, id, %DateTime{} = now),
    do: set_ignored(scope, id, %{ignored_at: nil, ignored_by_user_id: nil}, now)

  defp set_ignored(scope, id, attrs, now) do
    with {:ok, c} <- Conversations.fetch(scope, :triage, id),
         :ok <- unlinked(c) do
      fn -> ignored(scope, c, attrs, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp ignored(scope, c, attrs, now) do
    action = if attrs.ignored_at, do: "ignored", else: "unignored"

    with {:ok, updated} <- Store.update(c, attrs) do
      {:ok, _audit} =
        Audit.record(scope, action, updated,
          after: %{"ignored_at" => attrs.ignored_at, "team_id" => c.team_id},
          now: now
        )

      {:ok, updated, [Realtime.triage_changed(c.team_id)]}
    end
  end

  defp unlinked(%{links: []}), do: :ok

  defp unlinked(_c),
    do: Leads.invalid("id", "is linked to a lead: only a triage item is ignored")

  @doc """
  `POST /conversations/:id/create-lead {profile_id, job: {…P3's job body…}}`:
  P4a's `POST /leads` in the conversation's team, applied `recruiter_inbound`
  at the `inbound` stage, and the link (`created_from_triage`), in one
  transaction. Answers `{:ok, %{lead: card, conversation}}`.
  """
  @spec create_lead(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create_lead(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, c} <- Conversations.fetch(scope, :triage, id),
         {:ok, job} <- job_body(params["job"]) do
      first = c.id |> List.wrap() |> Store.messages() |> List.first()

      body = %{
        "team_id" => c.team_id,
        "job" => job,
        "profile_id" => params["profile_id"],
        "as" => "apply",
        "applied_via" => "recruiter_inbound",
        "applied_at" => first && DateTime.to_iso8601(Enum.min([first.sent_at, now], DateTime))
      }

      fn -> lead_made(scope, c, body, now) end
      |> Write.commit()
      |> case do
        {:ok, {lead, c}} -> {:ok, made(scope, lead, c, now)}
        error -> error
      end
    end
  end

  defp lead_made(scope, c, body, now) do
    with {:ok, sheet} <- Leads.create(scope, body, now, stage_kind: :inbound),
         lead = Data.Leads.get(c.organisation_id, sheet.id),
         {:ok, _how, events} <- Record.link(scope, c, lead, :created_from_triage, :sure, now) do
      {:ok, {lead, c}, events}
    end
  end

  defp made(scope, lead, c, now) do
    ctx = Signals.context(scope.organisation, [lead], now)
    lead = Data.Leads.reload(lead)

    %{
      lead: Sheet.card(lead, Sheet.today(scope, now), Signals.for_lead(ctx, lead)),
      conversation: Conversations.view(scope, Store.reload(c))
    }
  end

  # P3's job create needs the link: without one, the field error the form shows.
  defp job_body(%{} = job) do
    if Leads.blank(job["url"] || job[:url]),
      do: {:ok, job},
      else: Leads.invalid("job.url", "Add the job's link.")
  end

  defp job_body(nil), do: {:error, {:missing, [:job]}}
  defp job_body(_other), do: Leads.invalid("job", "is P3's job body")

  @doc """
  `POST /conversations/:id/recruiter {contact_id? | contact: {name,
  handles}, lead_id?}`: the sender as a contact — an existing one, or one
  made (a handle another contact holds is that contact) — the messages
  from its addresses made theirs, a participant, and with `lead_id` its
  recruiter. Answers `{conversation, contact}`.
  """
  @spec recruiter(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def recruiter(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, c} <- Conversations.fetch(scope, :triage, id),
         {:ok, lead} <- optional_lead(scope, params["lead_id"]) do
      fn -> recruited(scope, c, lead, params, now) end
      |> Write.commit()
      |> case do
        {:ok, {c, contact}} ->
          {:ok,
           %{
             conversation: Conversations.view(scope, Store.reload(c)),
             contact: Contacts.view(scope, ContactStore.reload(contact))
           }}

        error ->
          error
      end
    end
  end

  defp recruited(scope, c, lead, params, now) do
    with {:ok, contact} <- contact(scope, params, now) do
      addresses = for h <- contact.handles, h.kind == :email, do: h.value_normalized
      _made_theirs = Store.attribute_senders(c.id, addresses, contact.id)
      :ok = Store.add_participant(c.id, contact.id)
      {:ok, {c, contact}, [as_recruiter(scope, lead, contact, now), Record.changed(c)]}
    end
  end

  defp as_recruiter(_scope, nil, _contact, _now), do: []

  defp as_recruiter(scope, lead, contact, now) do
    case LeadLinks.linked(scope, lead, contact, :recruiter, now) do
      {:ok, _link, events} -> events
      {:ok, _held} -> []
      error -> error |> elem(1) |> Data.Repo.rollback()
    end
  end

  defp contact(scope, %{"contact_id" => id}, _now) when is_binary(id) and id != "" do
    case ContactStore.get(Scope.organisation_id(scope), id) do
      nil -> Leads.invalid("contact_id", "is not a contact")
      %{merged_into_contact_id: nil} = contact -> {:ok, contact}
      merged -> {:ok, ContactStore.get(merged.organisation_id, merged.merged_into_contact_id)}
    end
  end

  defp contact(scope, %{"contact" => %{} = body}, now) do
    body = Leads.stringify(body)

    with {:ok, handles} <- Contacts.handles(body["handles"]),
         name when is_binary(name) <-
           Leads.blank(body["name"]) || {:error, {:missing, [:contact]}} do
      case Contacts.insert(scope, body, String.trim(name), handles, now, source: "email") do
        {:ok, {_how, contact}} ->
          {:ok, ContactStore.reload(contact)}

        {:error, {:contact_exists, %{contact_id: id}}} ->
          {:ok, ContactStore.get(Scope.organisation_id(scope), id)}

        error ->
          error
      end
    end
  end

  defp contact(_scope, _params, _now), do: {:error, {:missing, [:contact_id]}}

  defp lead(_scope, nil), do: {:error, {:missing, [:lead_id]}}
  defp lead(scope, id), do: Leads.fetch(scope, :converse, id)

  defp optional_lead(_scope, id) when id in [nil, ""], do: {:ok, nil}
  defp optional_lead(scope, id), do: Leads.fetch(scope, :converse, id)

  defp staff(scope), do: if(Scope.customer?(scope), do: {:error, :not_found}, else: :ok)

  defp answer({:ok, c}, scope), do: {:ok, Conversations.view(scope, Store.reload(c))}
  defp answer(error, _scope), do: error
end
