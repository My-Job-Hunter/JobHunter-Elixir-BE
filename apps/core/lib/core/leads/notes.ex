defmodule Core.Leads.Notes do
  @moduledoc """
  A lead's notes (AQ-04B §4, §8.1, QP4b-13): **staff only**, markdown, a
  table of their own. Whoever may change the lead adds one ("Only the people
  working this lead can add a note."), which writes `note_added` (staff) in
  the ledger and so counts as activity; its author or a team lead edits or
  deletes it ("Only its author or a team lead can change a note."), audited,
  not an event. A customer finds no note at all.

  Every write is one transaction and tells `lead:<id>` `notes_changed`
  (and `event_added` for a new note) after commit.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Leads
  alias Core.Leads.Ledger
  alias Core.Realtime
  alias Core.Tasks.{Person, Write}
  alias Data.LeadNotes, as: Store
  alias Data.Leads.Note
  alias Data.Scope

  @doc "`GET /leads/:id/notes`: newest first, each with what the caller may do."
  @spec list(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, lead_id) do
    with :ok <- staff(scope),
         {:ok, lead} <- Leads.fetch(scope, :read, lead_id) do
      {:ok, Enum.map(Store.list(lead.id), &view(scope, lead, &1))}
    end
  end

  @doc "`POST /leads/:id/notes {body_md}`: the note, and `note_added` in the ledger."
  @spec add(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def add(%Scope{} = scope, lead_id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- staff(scope),
         {:ok, lead} <- Leads.fetch(scope, :note, lead_id),
         {:ok, body} <- body(params) do
      fn -> added(scope, lead, body, now) end
      |> Write.commit()
      |> answer(scope, lead)
    end
  end

  @doc "`PATCH /lead-notes/:id {body_md}`: its author's or a team lead's; audited."
  @spec edit(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def edit(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, note, lead} <- fetch(scope, :edit, id),
         {:ok, body} <- body(params) do
      if body == note.body_md,
        do: {:ok, view(scope, lead, note)},
        else: edit_write(scope, lead, note, body, now)
    end
  end

  @doc "`DELETE /lead-notes/:id`: its author's or a team lead's; audited. Its ledger row stays, unlinked."
  @spec delete(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, note, lead} <- fetch(scope, :delete, id),
         {:ok, _deleted} <- Write.commit(fn -> deleted(scope, lead, note, now) end),
         do: :ok
  end

  defp added(scope, lead, body, now) do
    attrs = %{
      organisation_id: lead.organisation_id,
      lead_id: lead.id,
      author_user_id: Scope.user_id(scope),
      body_md: body
    }

    with {:ok, note} <- Store.create(attrs) do
      _event = Ledger.record(scope, lead, :note_added, %{note_id: note.id}, now)
      {:ok, _audit} = Audit.record(scope, "created", note, after: snapshot(lead, note), now: now)

      {:ok, note,
       [
         Realtime.lead_topic("notes_changed", lead.id),
         Realtime.lead_topic("event_added", lead.id),
         Realtime.lead_events("lead_updated", lead)
       ]}
    end
  end

  defp edit_write(scope, lead, note, body, now),
    do: answer(Write.commit(fn -> edited(scope, lead, note, body, now) end), scope, lead)

  defp edited(scope, lead, note, body, now) do
    with {:ok, updated} <- Store.update(note, %{body_md: body}) do
      {:ok, _audit} =
        Audit.record(scope, "updated", updated,
          before: snapshot(lead, note),
          after: snapshot(lead, updated),
          now: now
        )

      {:ok, updated, [Realtime.lead_topic("notes_changed", lead.id)]}
    end
  end

  defp deleted(scope, lead, note, now) do
    with {:ok, deleted} <- Store.delete(note) do
      {:ok, _audit} =
        Audit.record(scope, "deleted", deleted, before: snapshot(lead, note), now: now)

      {:ok, deleted,
       [
         Realtime.lead_topic("notes_changed", lead.id),
         Realtime.lead_topic("event_added", lead.id)
       ]}
    end
  end

  @doc "The note shape (§8.4): `{id, body_md, author, inserted_at, updated_at, can: {edit, delete}}`."
  @spec view(Scope.t(), map(), Note.t()) :: map()
  def view(%Scope{} = scope, lead, %Note{} = note) do
    subject = {:lead_note, %{author_user_id: note.author_user_id, lead: Leads.subject(lead)}}

    %{
      id: note.id,
      body_md: note.body_md,
      author: Person.view(note.author_user),
      inserted_at: note.inserted_at,
      updated_at: note.updated_at,
      can: %{
        edit: Access.can?(scope, :edit, subject),
        delete: Access.can?(scope, :delete, subject)
      }
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp fetch(scope, action, id) do
    with :ok <- staff(scope),
         %Note{} = note <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         %{} = lead <- Data.Leads.get(note.organisation_id, note.lead_id) || {:error, :not_found},
         :ok <-
           Access.why_not(
             scope,
             action,
             {:lead_note, %{author_user_id: note.author_user_id, lead: Leads.subject(lead)}}
           ),
         do: {:ok, note, lead}
  end

  # A customer reads no note, and is told nothing exists.
  defp staff(scope), do: if(Scope.customer?(scope), do: {:error, :not_found}, else: :ok)

  defp body(params) do
    case Leads.blank(params["body_md"]) do
      nil -> {:error, {:missing, [:body_md]}}
      body when byte_size(body) > 40_000 -> Leads.invalid("body_md", "is too long")
      body -> {:ok, String.trim(body)}
    end
  end

  defp answer({:ok, note}, scope, lead) do
    note = Store.get(note.organisation_id, note.id)
    {:ok, view(scope, lead, note)}
  end

  defp answer(error, _scope, _lead), do: error

  defp snapshot(lead, note) do
    note
    |> Audit.snapshot([:lead_id, :author_user_id, :body_md])
    |> Map.merge(%{"team_id" => lead.job.team_id, "customer_id" => lead.profile.customer_id})
  end
end
