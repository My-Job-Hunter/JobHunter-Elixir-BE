defmodule Core.Contacts do
  @moduledoc """
  Contacts (AQ-06 P6.0, §6): the list, a contact's page, the match check,
  *New contact* (the check re-run in its transaction: an exact handle is
  `{:error, {:contact_exists, %{contact_id, name, kind}}}`, the 409), the
  edit, handles, *Merge* (every link moved by `Data.Contacts.merge/4`,
  QP6-4), and a lead's contacts (`Core.Contacts.LeadLinks`).

  **The organisation's** (QP6-2): every staff member reads, adds and edits
  them; merging is a team lead's or the system admin's; the customer finds
  none (`Core.Access`, `{:contact, _}`). Every write is audited.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Contacts.Match
  alias Core.Leads
  alias Core.Tasks.{Person, Write}
  alias Data.Companies
  alias Data.Contacts, as: Store
  alias Data.Contacts.{Contact, Handle}
  alias Data.Scope

  @audited ~w(name title company_id time_zone location is_do_not_contact notes_md
              merged_into_contact_id)a
  @page 50

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The contact behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Contact.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with :ok <- Access.why_not(scope, :read, {:contact, %{}}),
         %Contact{} = contact <-
           Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:contact, contact}),
         do: {:ok, contact}
  end

  @doc "`GET /contacts?q&company_id&cursor`: the contacts page, `{items, next_cursor}`."
  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :read, {:contact, %{}}),
         {:ok, after_row} <- cursor(params["cursor"]) do
      rows =
        Store.list(Scope.organisation_id(scope),
          q: blank_normalized(params["q"]),
          company_id: Leads.blank(params["company_id"]),
          after: after_row,
          limit: @page
        )

      items = Enum.take(rows, @page)

      next =
        if length(rows) > @page,
          do: items |> List.last() |> then(&encode([&1.name_normalized, &1.id]))

      {:ok, %{items: Enum.map(items, &row(scope, &1)), next_cursor: next}}
    end
  end

  @doc "`GET /contacts/:id`: the contact with its leads (those the caller sees)."
  @spec get(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, contact} <- fetch(scope, :read, id), do: {:ok, view(scope, contact)}
  end

  # ── The match check ─────────────────────────────────────────────────────────

  @doc "`POST /contacts/match {name, company_id?, company_name?, handles: [{kind, value}]}`: the **match**."
  @spec match(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def match(%Scope{} = scope, params) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :read, {:contact, %{}}),
         {:ok, handles} <- handles(params["handles"]) do
      found = assess(scope, params["name"], company_id(scope, params), handles)
      {:ok, match_view(scope, found)}
    end
  end

  @doc false
  # The match's answer, read in the caller's transaction or outside one.
  def assess(scope, name, company_id, handles) do
    org = Scope.organisation_id(scope)
    normalized = Contact.normalize(name || "") || ""
    exact = Store.by_handles(org, Enum.map(handles, &{&1.kind, &1.normalized}))
    Match.decide(exact, Store.similar(org, normalized, Match.threshold()), normalized, company_id)
  end

  @doc "The match as it is answered."
  @spec match_view(Scope.t(), map()) :: map()
  def match_view(scope, %{answer: answer, contact: contact, candidates: candidates}) do
    %{
      answer: answer,
      contact: contact && view(scope, contact),
      candidates: Enum.map(candidates, &view(scope, &1))
    }
  end

  # ── Create, edit ────────────────────────────────────────────────────────────

  @doc """
  `POST /contacts {name, title?, company_id? | company: {name}, time_zone?,
  location?, notes_md?, handles: [{kind, value}], use_possible: bool?}`. The
  match runs again in the transaction: an exact handle is
  `{:error, {:contact_exists, %{contact_id, name, kind}}}`. With `use_possible: true` and a
  possible match, the first candidate is used (the typed handles it lacks
  added to it) and nothing new is made: `{:ok, {:used, view}}`; else
  `{:ok, {:created, view}}`. `opts[:source]` is the server's (the
  extension's `extension`, an `.eml`'s `email`).
  """
  @spec create(Scope.t(), map(), DateTime.t(), keyword()) ::
          {:ok, {:created | :used, map()}} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now, opts \\ []) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :create, {:contact, %{}}),
         {:ok, handles} <- handles(params["handles"]),
         {:ok, name} <- name(params["name"]) do
      Write.commit(fn -> insert(scope, params, name, handles, now, opts) end)
      |> case do
        {:ok, {how, contact}} -> {:ok, {how, view(scope, Store.reload(contact))}}
        error -> error
      end
    end
  end

  @doc false
  # Inside a transaction: the contact made (or used), its handles, audited.
  def insert(scope, params, name, handles, now, opts \\ []) do
    company_id = company_for_write(scope, params, now)
    use_possible? = params["use_possible"] in [true, "true"]

    case assess(scope, name, company_id, handles) do
      %{answer: :exact, contact: contact} ->
        {:error, {:contact_exists, exists(contact, handles)}}

      %{answer: :possible, candidates: [first | _rest]} when use_possible? ->
        with :ok <- put_handles(scope, first, handles), do: {:ok, {:used, first}}

      _new_or_possible ->
        attrs =
          params
          |> Map.take(~w(title time_zone location notes_md))
          |> Map.merge(%{
            "name" => name,
            "company_id" => company_id,
            "organisation_id" => Scope.organisation_id(scope),
            "created_by_user_id" => Scope.user_id(scope),
            "source" => opts[:source] || "manual"
          })

        with {:ok, contact} <- Store.create(attrs),
             :ok <- put_handles(scope, contact, handles) do
          {:ok, _audit} =
            Audit.record(scope, "created", contact, after: snapshot(contact), now: now)

          {:ok, {:created, contact}}
        end
    end
  end

  @doc false
  # What the 409 names: the contact, and the kind of the handle it holds.
  def exists(contact, handles) do
    held = MapSet.new(contact.handles, &{&1.kind, &1.value_normalized})
    hit = Enum.find(handles, &MapSet.member?(held, {&1.kind, &1.normalized}))
    %{contact_id: contact.id, name: contact.name, kind: hit && hit.kind}
  end

  defp put_handles(scope, contact, handles) do
    Enum.reduce_while(handles, :ok, fn h, :ok ->
      case add_one(scope, contact, h) do
        {:ok, _handle} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A handle another contact holds is that contact (the 409); one this
  # contact holds already is kept.
  defp add_one(scope, contact, %{kind: kind, value: value, normalized: normalized}) do
    org = Scope.organisation_id(scope)

    case Store.by_handles(org, [{kind, normalized}]) do
      [%{id: id} = holder | _rest] when id != contact.id ->
        {:error, {:contact_exists, %{contact_id: holder.id, name: holder.name, kind: kind}}}

      [_this | _rest] ->
        {:ok, :held}

      [] ->
        Store.add_handle(%{
          organisation_id: org,
          contact_id: contact.id,
          kind: kind,
          value: value
        })
    end
  end

  @doc "`PATCH /contacts/:id`: its fields (and `company: {name}`), audited with what changed."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, contact} <- fetch(scope, :edit, id) do
      fn -> edited(scope, contact, params, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp edited(scope, contact, params, now) do
    attrs =
      params
      |> Map.take(Enum.map(Contact.fields(), &to_string/1) ++ ["is_do_not_contact"])
      |> then(&company_attrs(scope, &1, params, now))

    with {:ok, updated} <- Store.update(contact, attrs) do
      audit_change(scope, contact, updated, now)
      {:ok, updated}
    end
  end

  defp company_attrs(scope, attrs, %{"company" => %{"name" => _name} = company}, now),
    do: Map.put(attrs, "company_id", Core.Companies.find_or_insert(scope, company, now).id)

  defp company_attrs(_scope, attrs, _params, _now), do: attrs

  @doc false
  def audit_change(scope, before, updated, now) do
    old = snapshot(before)
    new = snapshot(updated)
    keys = for {k, v} <- new, old[k] != v, do: k

    if keys != [] do
      {:ok, _audit} =
        Audit.record(scope, "updated", updated,
          before: Map.take(old, keys),
          after: Map.take(new, keys),
          now: now
        )
    end

    :ok
  end

  @doc "`POST /contacts/:id/handles {kind, value}`: one more way in; another contact's is the 409."
  @spec add_handle(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def add_handle(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, contact} <- fetch(scope, :edit, id),
         {:ok, [handle]} <- handles([Leads.stringify(params)]) do
      fn -> handle_added(scope, contact, handle, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp handle_added(scope, contact, handle, now) do
    with {:ok, added} <- add_one(scope, contact, handle) do
      if match?(%Handle{}, added),
        do: Audit.record(scope, "created", added, after: handle_snapshot(added), now: now)

      {:ok, contact}
    end
  end

  @doc "`DELETE /contact-handles/:id`, audited."
  @spec remove_handle(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def remove_handle(%Scope{} = scope, id, %DateTime{} = now) do
    with %Handle{} = handle <-
           Store.get_handle(Scope.organisation_id(scope), id) || {:error, :not_found},
         {:ok, _contact} <- fetch(scope, :edit, handle.contact_id),
         {:ok, _gone} <- Write.commit(fn -> handle_removed(scope, handle, now) end),
         do: :ok
  end

  defp handle_removed(scope, handle, now) do
    with {:ok, gone} <- Store.delete_handle(handle) do
      {:ok, _audit} =
        Audit.record(scope, "deleted", gone, before: handle_snapshot(gone), now: now)

      {:ok, gone}
    end
  end

  # ── Merge ───────────────────────────────────────────────────────────────────

  @doc """
  `POST /contacts/:id/merge {into_contact_id}` (QP6-4): a team lead's or
  the system admin's. Every link moves to the survivor in one transaction,
  with a `contact_merges` row and an audit row. Answers the survivor.
  """
  @spec merge(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def merge(%Scope{} = scope, id, params, %DateTime{} = now) do
    into_id = Leads.stringify(params)["into_contact_id"]

    with {:ok, from} <- fetch(scope, :merge, id),
         :ok <- live(from, "id"),
         {:ok, into} <- into(scope, into_id, from) do
      fn -> merged(scope, from, into, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp merged(scope, from, into, now) do
    with {:ok, _merge} <- Store.merge(from, into, Scope.user_id(scope), now) do
      {:ok, _audit} =
        Audit.record(scope, "merged", from,
          before: snapshot(from),
          after: %{"merged_into_contact_id" => into.id},
          now: now
        )

      {:ok, into}
    end
  end

  defp into(_scope, nil, _from), do: {:error, {:missing, [:into_contact_id]}}

  defp into(scope, id, from) do
    case Store.get(Scope.organisation_id(scope), id) do
      nil -> Leads.invalid("into_contact_id", "is not a contact")
      %{id: same} when same == from.id -> Leads.invalid("into_contact_id", "is this contact")
      into -> with :ok <- live(into, "into_contact_id"), do: {:ok, into}
    end
  end

  defp live(%Contact{merged_into_contact_id: nil}, _field), do: :ok
  defp live(_contact, field), do: Leads.invalid(field, "was merged into another contact")

  # ── The shapes (§11.6) ──────────────────────────────────────────────────────

  @doc "**contact**: the page's, with the leads the caller sees."
  @spec view(Scope.t(), Contact.t()) :: map()
  def view(%Scope{} = scope, %Contact{} = contact) do
    leads =
      for lc <- Store.leads_of(contact.id),
          lead = Data.Leads.fill(lc.lead),
          Access.can?(scope, :read, {:lead, Leads.subject(lead)}),
          do: %{
            id: lead.id,
            title: lead.job.title,
            company: lead.job.company && %{id: lead.job.company.id, name: lead.job.company.name},
            role: lc.role,
            state: lead.state
          }

    contact
    |> base(scope)
    |> Map.merge(%{leads: leads, leads_count: contact.leads_count})
  end

  @doc "The contacts page's row: no leads, `leads_count`."
  @spec row(Scope.t(), Contact.t()) :: map()
  def row(%Scope{} = scope, %Contact{} = contact),
    do: contact |> base(scope) |> Map.put(:leads_count, contact.leads_count)

  @doc "A contact as a conversation or a meeting names it: `{id, name}`."
  @spec ref(Contact.t() | nil) :: map() | nil
  def ref(nil), do: nil
  def ref(%Contact{} = c), do: %{id: c.id, name: c.name}

  defp base(contact, scope) do
    may = &Access.can?(scope, &1, {:contact, contact})

    %{
      id: contact.id,
      name: contact.name,
      title: contact.title,
      company: contact.company && %{id: contact.company.id, name: contact.company.name},
      time_zone: contact.time_zone,
      location: contact.location,
      source: contact.source,
      handles:
        Enum.map(contact.handles, fn h ->
          %{id: h.id, kind: h.kind, value: h.value, is_invalid: h.is_invalid}
        end),
      is_do_not_contact: contact.is_do_not_contact,
      notes_md: contact.notes_md,
      merged_into: contact.merged_into_contact && ref(contact.merged_into_contact),
      created_by: Person.view(contact.created_by_user),
      can: %{edit: may.(:edit), merge: may.(:merge) and is_nil(contact.merged_into_contact_id)}
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc false
  # `[{kind, value}]` as sent: each normalised, or the field error.
  def handles(nil), do: {:ok, []}

  def handles(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {h, i}, {:ok, acc} ->
      h = Leads.stringify(h)

      case Handle.normalize(to_string(h["kind"] || ""), h["value"]) do
        {:ok, normalized} ->
          kind = String.to_existing_atom(to_string(h["kind"]))

          {:cont,
           {:ok, [%{kind: kind, value: String.trim(h["value"]), normalized: normalized} | acc]}}

        {:error, message} ->
          {:halt, Leads.invalid("handles.#{i}", message)}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq_by(&{&1.kind, &1.normalized})}
      error -> error
    end)
  end

  def handles(_other), do: Leads.invalid("handles", "is a list of {kind, value}")

  defp name(name) do
    case Leads.blank(name) do
      nil -> {:error, {:missing, [:name]}}
      name -> {:ok, String.trim(name)}
    end
  end

  # The company a match compares: `company_id`, or one named so by `company_name`.
  defp company_id(scope, params) do
    cond do
      id = Leads.blank(params["company_id"]) ->
        id

      name = Leads.blank(params["company_name"]) ->
        company_by_name(scope, name)

      match?(%{"name" => _}, params["company"]) ->
        company_by_name(scope, params["company"]["name"])

      true ->
        nil
    end
  end

  defp company_by_name(scope, name) do
    case Companies.get_by_name(Scope.organisation_id(scope), name) do
      nil -> nil
      company -> company.id
    end
  end

  # On a write, `company: {name}` makes the company when it is new.
  defp company_for_write(scope, %{"company" => %{"name" => name} = company}, now)
       when is_binary(name) and name != "",
       do: Core.Companies.find_or_insert(scope, company, now).id

  defp company_for_write(scope, params, _now) do
    case Leads.blank(params["company_id"]) do
      nil ->
        nil

      id ->
        case Companies.get(Scope.organisation_id(scope), id) do
          nil -> nil
          company -> company.id
        end
    end
  end

  defp blank_normalized(q), do: if(q = Leads.blank(q), do: Contact.normalize(q))

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, [name, id]} <- Jason.decode(json) do
      {:ok, {name, id}}
    else
      _bad -> Leads.invalid("cursor", "is not a cursor of this list")
    end
  end

  defp encode(row), do: row |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp answer({:ok, contact}, scope), do: {:ok, view(scope, Store.reload(contact))}
  defp answer(error, _scope), do: error

  @doc false
  def snapshot(contact), do: Audit.snapshot(contact, @audited)

  defp handle_snapshot(h), do: Audit.snapshot(h, [:contact_id, :kind, :value, :is_invalid])
end
