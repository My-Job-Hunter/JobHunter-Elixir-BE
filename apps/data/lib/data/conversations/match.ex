defmodule Data.Conversations.Match do
  @moduledoc """
  The reads AQ-09 §7's matching makes, beyond P6's: the leads holding a
  forwarded mail's referenced messages, a receiving customer's open leads
  holding a contact, its recent leads (for a platform's notice), and the
  open leads of a company by the sender's domain. Storage only: the rules
  are `Core.Conversations.Match`'s.

  **Open** is P6's: `todo · in_progress · on_hold`, not archived.
  """

  import Ecto.Query, warn: false

  alias Data.Companies.Company
  alias Data.Contacts.{Contact, Handle, LeadContact}
  alias Data.Conversations.{Conversation, ConversationLead, Message}
  alias Data.Jobs.Job
  alias Data.Leads.Lead
  alias Data.Repo

  @open [:todo, :in_progress, :on_hold]

  @doc """
  The teams among `team_ids` holding a message with one of `rfc_ids`,
  newest message first: where a forwarded reply's thread lives.
  """
  @spec teams_holding(binary(), [binary()], [String.t()]) :: [binary()]
  def teams_holding(_organisation_id, [], _rfc_ids), do: []
  def teams_holding(_organisation_id, _team_ids, []), do: []

  def teams_holding(organisation_id, team_ids, rfc_ids) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.organisation_id == ^organisation_id and c.team_id in ^team_ids and
          m.rfc_message_id in ^rfc_ids,
      order_by: [desc: m.sent_at],
      select: c.team_id
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  @doc """
  The leads linked to the team's conversations holding `rfc_ids`'
  messages, as `%{rfc_id => [lead_id]}` (rule 1's parents).
  """
  @spec leads_of_messages(binary(), binary(), [String.t()]) :: %{String.t() => [binary()]}
  def leads_of_messages(_organisation_id, _team_id, []), do: %{}

  def leads_of_messages(organisation_id, team_id, rfc_ids) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      join: l in ConversationLead,
      on: l.conversation_id == c.id,
      where:
        m.organisation_id == ^organisation_id and c.team_id == ^team_id and
          m.rfc_message_id in ^rfc_ids,
      order_by: [asc: l.inserted_at],
      select: {m.rfc_message_id, l.lead_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {rfc, leads} -> {rfc, Enum.uniq(leads)} end)
  end

  @doc """
  The customer's open leads holding one of `contact_ids` (rule 2), narrowed
  to `profile_id` and `team_id` when given: `[{lead_id, team_id}]`, most
  recently active first.
  """
  @spec customer_leads_holding(binary(), [binary()], keyword()) :: [{binary(), binary()}]
  def customer_leads_holding(_customer_id, [], _opts), do: []

  def customer_leads_holding(customer_id, contact_ids, opts) do
    from(lc in LeadContact,
      join: l in Lead,
      as: :lead,
      on: l.id == lc.lead_id,
      join: j in assoc(l, :job),
      as: :job,
      join: p in assoc(l, :profile),
      where:
        lc.contact_id in ^contact_ids and p.customer_id == ^customer_id and l.state in ^@open and
          is_nil(l.archived_at),
      order_by: [desc: l.last_activity_at, asc: l.id],
      select: {l.id, j.team_id}
    )
    |> narrow(opts)
    |> Repo.all()
    |> Enum.uniq()
  end

  @doc """
  The customer's open leads applied (or made) since `since` (rule 5),
  narrowed to `team_id` when given: `[%{id, team_id, title, company}]`.
  """
  @spec recent_leads(binary(), DateTime.t(), keyword()) :: [map()]
  def recent_leads(customer_id, %DateTime{} = since, opts) do
    from(l in Lead,
      as: :lead,
      join: j in assoc(l, :job),
      as: :job,
      join: p in assoc(l, :profile),
      left_join: co in assoc(j, :company),
      where:
        p.customer_id == ^customer_id and l.state in ^@open and is_nil(l.archived_at) and
          coalesce(l.applied_at, l.inserted_at) >= ^since,
      order_by: [desc: coalesce(l.applied_at, l.inserted_at), asc: l.id],
      select: %{id: l.id, team_id: j.team_id, title: j.title, company: co.name}
    )
    |> narrow(opts)
    |> Repo.all()
  end

  defp narrow(query, opts) do
    query
    |> then(&if(opts[:team_id], do: where(&1, [job: j], j.team_id == ^opts[:team_id]), else: &1))
    |> then(
      &if(opts[:profile_id],
        do: where(&1, [lead: l], l.profile_id == ^opts[:profile_id]),
        else: &1
      )
    )
  end

  @doc """
  The team's open leads whose job's company is at `domain` (rule 4): the
  company's `domain`, its website's host, or the address of one of its
  contacts. `customer_id` narrows to one customer's. `[{lead_id,
  company_name}]`.
  """
  @spec leads_at_domain(binary(), binary(), String.t(), binary() | nil) :: [
          {binary(), String.t()}
        ]
  def leads_at_domain(organisation_id, team_id, domain, customer_id) do
    companies = companies_at(organisation_id, domain)

    from(l in Lead,
      join: j in Job,
      on: j.id == l.job_id,
      join: co in Company,
      on: co.id == j.company_id,
      join: p in assoc(l, :profile),
      where:
        j.team_id == ^team_id and j.company_id in subquery(companies) and l.state in ^@open and
          is_nil(l.archived_at),
      order_by: [desc: l.last_activity_at, asc: l.id],
      select: {l.id, co.name, p.customer_id}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, _name, cid} -> is_nil(customer_id) or cid == customer_id end)
    |> Enum.map(fn {id, name, _cid} -> {id, name} end)
  end

  # The organisation's companies at a domain: their own, their website's, a contact's.
  defp companies_at(organisation_id, domain) do
    at = "%@" <> Data.Companies.escape_like(domain)

    by_contact =
      from(h in Handle,
        join: ct in Contact,
        on: ct.id == h.contact_id,
        where:
          h.organisation_id == ^organisation_id and h.kind == :email and
            like(h.value_normalized, ^at) and not is_nil(ct.company_id),
        select: ct.company_id
      )

    from(co in Company,
      where:
        co.organisation_id == ^organisation_id and
          (fragment("lower(?)", co.domain) == ^domain or
             fragment(
               "lower(regexp_replace(?, '^[a-zA-Z]+://(www[.])*([^/:#]+).*$', '\\2'))",
               co.website_url
             ) == ^domain or co.id in subquery(by_contact)),
      select: co.id
    )
  end
end
