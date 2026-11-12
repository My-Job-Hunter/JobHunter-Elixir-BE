defmodule Data.Contacts do
  @moduledoc """
  Contacts, their handles, their merges and their leads (AQ-06 §5.1).
  Storage only: who may read, add or merge one is `Core.Access`'s, the
  match `Core.Contacts.Match`'s, the rest `Core.Contacts`'s. Every read is
  the organisation's.
  """

  import Ecto.Query, warn: false

  alias Data.Contacts.{Contact, Handle, LeadContact, Merge}
  alias Data.Conversations.{Message, Participant}
  alias Data.Leads.{Event, Lead}
  alias Data.Meetings.Attendee
  alias Data.Repo

  @preload [
    :company,
    :merged_into_contact,
    handles: from(h in Handle, order_by: [asc: h.inserted_at, asc: h.id]),
    created_by_user: [person: :photo]
  ]
  @open [:todo, :in_progress, :on_hold]

  @doc "What every contact read carries."
  def preload, do: @preload

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "A contact of the organisation with its handles, company and count of leads; `nil` otherwise."
  @spec get(binary(), term()) :: Contact.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Contact |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The contact again, fresh."
  @spec reload(Contact.t()) :: Contact.t()
  def reload(%Contact{} = contact), do: contact.organisation_id |> get(contact.id)

  @doc "Several contacts by id, with what a read carries."
  @spec get_many(binary(), [binary()]) :: [Contact.t()]
  def get_many(_organisation_id, []), do: []

  def get_many(organisation_id, ids) do
    from(c in Contact, where: c.organisation_id == ^organisation_id and c.id in ^ids)
    |> load_all()
  end

  @doc """
  A page of the organisation's live contacts (not merged), by name then id:
  `q` (normalised; a name by substring or trigram, or a handle's value),
  `company_id`, `after` (`{name_normalized, id}` of the last row shown),
  `limit`. Reads `limit + 1`.
  """
  @spec list(binary(), keyword()) :: [Contact.t()]
  def list(organisation_id, opts) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in Contact,
      where: c.organisation_id == ^organisation_id and is_nil(c.merged_into_contact_id),
      order_by: [asc: c.name_normalized, asc: c.id],
      limit: ^(limit + 1)
    )
    |> search(opts[:q])
    |> company(opts[:company_id])
    |> after_row(opts[:after])
    |> load_all()
  end

  defp search(query, nil), do: query

  defp search(query, qn) do
    like = "%" <> Data.Companies.escape_like(qn) <> "%"
    handle = from(h in Handle, where: like(h.value_normalized, ^like), select: h.contact_id)

    where(
      query,
      [c],
      like(c.name_normalized, ^like) or fragment("? % ?", c.name_normalized, ^qn) or
        c.id in subquery(handle)
    )
  end

  defp company(query, nil), do: query
  defp company(query, id), do: where(query, [c], c.company_id == ^id)

  defp after_row(query, nil), do: query

  defp after_row(query, {name, id}),
    do:
      where(query, [c], c.name_normalized > ^name or (c.name_normalized == ^name and c.id > ^id))

  @doc """
  The contacts holding any of `handles` (`[{kind, value_normalized}]`),
  each as its survivor when it was merged: the match's *exact* answer.
  """
  @spec by_handles(binary(), [{atom(), String.t()}]) :: [Contact.t()]
  def by_handles(_organisation_id, []), do: []

  def by_handles(organisation_id, handles) do
    pairs = Enum.map(handles, fn {kind, value} -> "#{kind}:#{value}" end)

    ids =
      from(h in Handle,
        join: c in Contact,
        on: c.id == h.contact_id,
        where:
          h.organisation_id == ^organisation_id and
            fragment("(? || ':' || ?)", h.kind, h.value_normalized) in ^pairs,
        select: coalesce(c.merged_into_contact_id, c.id),
        distinct: true
      )
      |> Repo.all()

    get_many(organisation_id, ids)
  end

  @doc """
  Live contacts whose normalised name is `name` or trigram-similar to it
  (≥ `threshold`), each with `similarity` set: the match's *possible*
  candidates, for `Core.Contacts.Match` to decide on.
  """
  @spec similar(binary(), String.t(), float()) :: [{Contact.t(), float()}]
  def similar(_organisation_id, "", _threshold), do: []

  def similar(organisation_id, name, threshold) do
    rows =
      from(c in Contact,
        where:
          c.organisation_id == ^organisation_id and is_nil(c.merged_into_contact_id) and
            (c.name_normalized == ^name or
               fragment("similarity(?, ?) >= ?", c.name_normalized, ^name, ^threshold)),
        select: {c.id, fragment("similarity(?, ?)", c.name_normalized, ^name)},
        limit: 20
      )
      |> Repo.all()

    scores = Map.new(rows)

    organisation_id
    |> get_many(Map.keys(scores))
    |> Enum.map(&{&1, Map.fetch!(scores, &1.id)})
  end

  @doc "A handle of the organisation, with its contact; `nil` otherwise."
  @spec get_handle(binary(), term()) :: Handle.t() | nil
  def get_handle(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Handle |> Repo.get_by(id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  def get_handle(_organisation_id, _id), do: nil

  @doc "The organisation's email handles among `values` (normalised), with their contacts."
  @spec email_handles(binary(), [String.t()]) :: [Handle.t()]
  def email_handles(_organisation_id, []), do: []

  def email_handles(organisation_id, values) do
    from(h in Handle,
      where:
        h.organisation_id == ^organisation_id and h.kind == :email and
          h.value_normalized in ^values,
      preload: [:contact]
    )
    |> Repo.all()
  end

  # ── Leads ───────────────────────────────────────────────────────────────────

  @doc "A lead's contacts, in the order they were linked, each with its contact read."
  @spec for_lead(binary()) :: [LeadContact.t()]
  def for_lead(lead_id) do
    from(lc in LeadContact,
      where: lc.lead_id == ^lead_id,
      order_by: [asc: lc.inserted_at, asc: lc.contact_id],
      preload: [contact: ^@preload]
    )
    |> Repo.all()
    |> Enum.map(fn lc -> %{lc | contact: fill_counts(lc.contact)} end)
  end

  @doc "The links of a contact to leads, each lead with what a card carries."
  @spec leads_of(binary()) :: [LeadContact.t()]
  def leads_of(contact_id) do
    from(lc in LeadContact,
      where: lc.contact_id == ^contact_id,
      order_by: [desc: lc.inserted_at],
      preload: [lead: ^Data.Leads.base_preload()]
    )
    |> Repo.all()
  end

  @doc "One link of a lead to a contact, or `nil`."
  @spec lead_contact(binary(), term()) :: LeadContact.t() | nil
  def lead_contact(lead_id, contact_id) when is_binary(contact_id) do
    case Ecto.UUID.cast(contact_id) do
      {:ok, uuid} -> Repo.get_by(LeadContact, lead_id: lead_id, contact_id: uuid)
      :error -> nil
    end
  end

  def lead_contact(_lead_id, _contact_id), do: nil

  @doc """
  The open, live leads of `team_id` that hold one of `contact_ids` as a
  contact (§7.2 rule 3), `profile_id` narrowing to one profile's (the
  extension's acting profile). Answers `[{lead_id, contact_id}]`.
  """
  @spec open_leads_holding(binary(), [binary()], binary() | nil) :: [{binary(), binary()}]
  def open_leads_holding(_team_id, [], _profile_id), do: []

  def open_leads_holding(team_id, contact_ids, profile_id) do
    from(lc in LeadContact,
      join: l in Lead,
      on: l.id == lc.lead_id,
      join: j in assoc(l, :job),
      where:
        lc.contact_id in ^contact_ids and j.team_id == ^team_id and l.state in ^@open and
          is_nil(l.archived_at),
      order_by: [desc: l.last_activity_at, asc: l.id],
      select: {l.id, lc.contact_id}
    )
    |> then(&if(profile_id, do: where(&1, [_lc, l], l.profile_id == ^profile_id), else: &1))
    |> Repo.all()
  end

  @doc "How many leads each contact is on: `%{contact_id => n}`."
  @spec leads_counts([binary()]) :: %{binary() => non_neg_integer()}
  def leads_counts([]), do: %{}

  def leads_counts(ids) do
    from(lc in LeadContact,
      where: lc.contact_id in ^ids,
      group_by: lc.contact_id,
      select: {lc.contact_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, contact} <- %Contact{} |> Contact.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(contact)}
  end

  @spec update(Contact.t(), map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Contact{} = contact, attrs) do
    with {:ok, updated} <- contact |> Contact.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @spec add_handle(map()) :: {:ok, Handle.t()} | {:error, Ecto.Changeset.t()}
  def add_handle(attrs), do: %Handle{} |> Handle.changeset(attrs) |> Repo.insert()

  @spec delete_handle(Handle.t()) :: {:ok, Handle.t()} | {:error, Ecto.Changeset.t()}
  def delete_handle(%Handle{} = handle), do: Repo.delete(handle)

  @doc "A handle marked invalid (a bounce)."
  @spec invalidate_handle(Handle.t()) :: {:ok, Handle.t()} | {:error, Ecto.Changeset.t()}
  def invalidate_handle(%Handle{} = handle),
    do: handle |> Handle.move_changeset(%{is_invalid: true}) |> Repo.update()

  @spec link_lead(map()) :: {:ok, LeadContact.t()} | {:error, Ecto.Changeset.t()}
  def link_lead(attrs), do: %LeadContact{} |> LeadContact.changeset(attrs) |> Repo.insert()

  @spec unlink_lead(LeadContact.t()) :: {:ok, LeadContact.t()} | {:error, Ecto.Changeset.t()}
  def unlink_lead(%LeadContact{} = link), do: Repo.delete(link)

  @doc """
  Every link of `from` moved to `into` (QP6-4), in the caller's
  transaction: handles, lead links, participations, meeting attendances,
  message authors and ledger rows. Where `into` already holds the same
  lead, conversation or meeting, `from`'s row goes. Then `from` points at
  `into`, and a `contact_merges` row keeps its name and handles.
  """
  @spec merge(Contact.t(), Contact.t(), binary() | nil, DateTime.t()) ::
          {:ok, Merge.t()} | {:error, Ecto.Changeset.t()}
  def merge(%Contact{} = from, %Contact{} = into, user_id, %DateTime{} = now) do
    handles = Enum.map(from.handles, &"#{&1.kind}: #{&1.value}")

    from(h in Handle, where: h.contact_id == ^from.id)
    |> Repo.update_all(set: [contact_id: into.id, updated_at: now])

    move_pairs(LeadContact, :lead_id, from.id, into.id)
    move_pairs(Participant, :conversation_id, from.id, into.id)
    move_pairs(Attendee, :meeting_id, from.id, into.id)

    from(m in Message, where: m.from_contact_id == ^from.id)
    |> Repo.update_all(set: [from_contact_id: into.id])

    from(e in Event, where: e.contact_id == ^from.id)
    |> Repo.update_all(set: [contact_id: into.id])

    {:ok, _merged} = from |> Contact.merged_changeset(into.id) |> Repo.update()

    %Merge{}
    |> Merge.changeset(%{
      organisation_id: from.organisation_id,
      into_contact_id: into.id,
      from_name: from.name,
      from_handles: handles,
      merged_by_user_id: user_id,
      merged_at: now
    })
    |> Repo.insert()
  end

  # Rows keyed by (`owner`, contact_id): the survivor's row wins where both
  # hold the same owner; the rest are re-pointed.
  defp move_pairs(schema, owner, from_id, into_id) do
    held = from(r in schema, where: r.contact_id == ^into_id, select: field(r, ^owner))

    from(r in schema, where: r.contact_id == ^from_id and field(r, ^owner) in subquery(held))
    |> Repo.delete_all()

    from(r in schema, where: r.contact_id == ^from_id)
    |> Repo.update_all(set: [contact_id: into_id])
  end

  @doc "The merges into a contact, newest first."
  @spec merges_into(binary()) :: [Merge.t()]
  def merges_into(contact_id) do
    Repo.all(
      from(m in Merge, where: m.into_contact_id == ^contact_id, order_by: [desc: m.merged_at])
    )
  end

  # ── Loading ─────────────────────────────────────────────────────────────────

  defp load(nil), do: nil
  defp load(contact), do: contact |> Repo.preload(@preload, force: true) |> fill_counts()

  defp load_all(query) do
    contacts = query |> preload(^@preload) |> Repo.all()
    counts = leads_counts(Enum.map(contacts, & &1.id))
    Enum.map(contacts, &%{&1 | leads_count: Map.get(counts, &1.id, 0)})
  end

  defp fill_counts(contact),
    do: %{contact | leads_count: Map.get(leads_counts([contact.id]), contact.id, 0)}
end
