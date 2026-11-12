defmodule Core.Meetings do
  @moduledoc """
  A lead's meetings (AQ-06 P6.4, §8): read, the Meetings page, and the
  verbs — **schedule** (`meeting_scheduled`; `move_to_stage` moves the
  lead through P4a's own move, one tap, never automatic, QP6-18),
  **reschedule** (new times, `sequence` + 1, `meeting_changed`, the
  reminders re-planned), **cancel** (`meeting_cancelled`, the reminders
  dropped), **done** and **no-show** (`meeting_done` with the outcome).
  Each is one transaction with its event, audit row, notices, reminder
  jobs and the after-commit `meeting_changed {lead, meeting}` on `lead:`
  and `customer:`.

  Seen with its lead and changed by whoever may change the lead (`:meet`,
  P4a's words); the customer reads their own, always, with no staff note
  and no clash (`Core.Access.Conversations`). A verb on a meeting that is
  not scheduled is a field error on `status` ("This meeting is already
  cancelled."). **The clash** (QP6-17) warns of the customer's scheduled
  meeting on another lead, any team — another team's (or one the reader
  may not see) named only as "another meeting" — and never blocks.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Contacts
  alias Core.Leads
  alias Core.Leads.{Act, Ledger}
  alias Core.Meetings.{Ics, Notices, Reminders, Sheet, Words}
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Meetings, as: Store
  alias Data.Meetings.Meeting
  alias Data.Scope
  alias Data.Teams

  @audited ~w(title meeting_kind platform join_url address starts_at ends_at time_zone status
              outcome_note sequence)a
  @calendar ~w(title platform join_url address)a

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The meeting behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Meeting.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Meeting{} = m <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:meeting, subject(m)}),
         do: {:ok, m}
  end

  @doc "What `Core.Access.Conversations` decides a meeting on."
  @spec subject(Meeting.t()) :: map()
  def subject(%Meeting{} = m),
    do: %{organisation_id: m.organisation_id, lead: Leads.subject(m.lead)}

  @doc "`GET /meetings/:id`."
  @spec get(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, m} <- fetch(scope, :read, id), do: {:ok, view(scope, m)}
  end

  @doc """
  `GET /meetings?team_id&from&to` (the console: the team's, by
  `peer_leads`) and the portal's `GET /meetings` (the customer's own).
  Without `from`/`to`, every scheduled meeting not yet over, upcoming
  first; with them, every meeting starting in the window (the week view).
  """
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, narrow} <- narrow(scope, params),
         {:ok, from} <- time(params["from"], "from"),
         {:ok, to} <- time(params["to"], "to") do
      items =
        (narrow ++ [from: from, to: to, now: now])
        |> Store.list()
        |> Enum.filter(&Access.can?(scope, :read, {:meeting, subject(&1)}))
        |> Enum.map(&view(scope, &1))

      {:ok, %{items: items}}
    end
  end

  defp narrow(scope, params) do
    if Scope.customer?(scope) do
      {:ok, [customer_id: Scope.customer_id(scope)]}
    else
      with {:ok, team} <- Core.Jobs.team(scope, params), do: {:ok, [team_id: team.id]}
    end
  end

  @doc """
  `GET /leads/:id/meetings` (its Meetings tab, a contact's page): the
  scheduled ones not yet over first, soonest first; then the rest, newest
  first.
  """
  @spec for_lead(Scope.t(), term(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def for_lead(%Scope{} = scope, lead_id, %DateTime{} = now) do
    with {:ok, lead} <- Leads.fetch(scope, :read, lead_id) do
      {upcoming, rest} =
        Enum.split_with(
          Store.for_lead(lead.id),
          &(&1.status == :scheduled and DateTime.after?(&1.ends_at, now))
        )

      {:ok,
       Enum.map(
         upcoming ++ Enum.sort_by(rest, & &1.starts_at, {:desc, DateTime}),
         &view(scope, &1)
       )}
    end
  end

  @doc "The meetings a contact attends that the caller may see (the contact's page)."
  @spec for_contact(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def for_contact(%Scope{} = scope, contact_id) do
    with {:ok, contact} <- Contacts.fetch(scope, :read, contact_id) do
      {:ok,
       for(
         lc <- ContactStore.leads_of(contact.id),
         m <- Store.for_lead(lc.lead_id),
         Enum.any?(m.attendees, &(&1.contact_id == contact.id)),
         Access.can?(scope, :read, {:meeting, subject(m)}),
         do: view(scope, m)
       )}
    end
  end

  # ── Schedule ────────────────────────────────────────────────────────────────

  @doc """
  `POST /leads/:id/meetings {title, meeting_kind, platform, join_url?,
  address?, starts_at, ends_at, time_zone, attendees: [{user_id} |
  {contact_id} | {customer: true}], notes_md?, move_to_stage?}`: answers
  the **meeting** with its `clash`.
  """
  @spec schedule(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def schedule(%Scope{} = scope, lead_id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :meet, lead_id),
         {:ok, starts, ends} <- times(params),
         {:ok, attendees} <- attendees(scope, lead, params["attendees"]),
         {:ok, stage} <- stage(lead, params["move_to_stage"]) do
      attrs =
        params
        |> Map.take(Enum.map(Meeting.editable(), &to_string/1) ++ ["time_zone"])
        |> Map.merge(%{
          "organisation_id" => lead.organisation_id,
          "lead_id" => lead.id,
          "starts_at" => starts,
          "ends_at" => ends,
          "created_by_user_id" => Scope.user_id(scope)
        })

      Write.commit(fn -> scheduled(scope, lead, attrs, attendees, stage, now) end)
      |> answer(scope)
    end
  end

  defp scheduled(scope, lead, attrs, attendees, stage, now) do
    with {:ok, m} <- Store.create(attrs),
         :ok <- put_attendees(m, attendees) do
      m = Store.reload(m)

      _event =
        Ledger.record(
          scope,
          lead,
          :meeting_scheduled,
          %{meeting_id: m.id, to_label: m.title, from_label: Words.at(m.starts_at, m.time_zone)},
          now
        )

      {:ok, _audit} = Audit.record(scope, "created", m, after: snapshot(m), now: now)
      :ok = Reminders.plan(m, now)

      with {:ok, _moved} <- move(scope, lead, stage, now) do
        {:ok, m, [Notices.scheduled(scope, m), events(lead, m)]}
      end
    end
  end

  # QP6-18: the stage the person took, through P4a's move.
  defp move(_scope, _lead, nil, _now), do: {:ok, nil}

  defp move(scope, lead, stage, now) do
    lead = Data.Leads.reload(lead)
    from = %{state: lead.state, stage: lead.stage && lead.stage.key}
    Act.run(scope, :move, lead.id, %{from: from, state: :in_progress, stage: stage.key}, now)
  end

  defp put_attendees(m, attendees) do
    Enum.reduce_while(attendees, :ok, fn a, :ok ->
      case Store.add_attendee(Map.put(a, :meeting_id, m.id)) do
        {:ok, _attendee} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ── Edit, reschedule, cancel, done, no-show ─────────────────────────────────

  @doc "`PATCH /meetings/:id {title?, meeting_kind?, platform?, join_url?, address?, notes_md?}`: audited; a calendar field moves `sequence`."
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, m} <- fetch(scope, :edit, id) do
      attrs = Map.take(params, Enum.map(Meeting.editable(), &to_string/1))

      fn -> edited(scope, m, attrs, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp edited(scope, m, attrs, now) do
    with {:ok, edited} <- Store.update(m, attrs) do
      edited =
        if Enum.any?(@calendar, &(Map.get(edited, &1) != Map.get(m, &1))),
          do: elem(Store.update(edited, %{sequence: m.sequence + 1}), 1),
          else: edited

      audit_change(scope, m, edited, now)
      {:ok, edited, [events(m.lead, edited)]}
    end
  end

  @doc "`POST /meetings/:id/reschedule {starts_at, ends_at, time_zone?}`: `sequence` + 1, `meeting_changed`, the reminders re-planned."
  @spec reschedule(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def reschedule(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, m} <- fetch(scope, :reschedule, id),
         :ok <- scheduled?(m),
         {:ok, starts, ends} <- times(params) do
      attrs =
        %{starts_at: starts, ends_at: ends, sequence: m.sequence + 1}
        |> then(
          &if(params["time_zone"], do: Map.put(&1, :time_zone, params["time_zone"]), else: &1)
        )

      fn -> rescheduled(scope, m, attrs, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp rescheduled(scope, m, attrs, now) do
    with {:ok, moved} <- Store.update(m, attrs) do
      labels = %{
        meeting_id: m.id,
        from_label: Words.at(m.starts_at, m.time_zone),
        to_label: Words.at(moved.starts_at, moved.time_zone)
      }

      _event = Ledger.record(scope, m.lead, :meeting_changed, labels, now)
      audit_change(scope, m, moved, now)
      :ok = Reminders.drop(m.id)
      :ok = Reminders.plan(moved, now)
      {:ok, moved, [Notices.changed(scope, moved), events(m.lead, moved)]}
    end
  end

  @doc "`POST /meetings/:id/cancel {outcome_note?}`: `meeting_cancelled`, `sequence` + 1, the reminders off."
  @spec cancel(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Scope{} = scope, id, params, %DateTime{} = now),
    do: finish(scope, :cancel, id, params, now)

  @doc "`POST /meetings/:id/done {outcome_note?}`: `meeting_done`."
  @spec done(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def done(%Scope{} = scope, id, params, %DateTime{} = now),
    do: finish(scope, :done, id, params, now)

  @doc "`POST /meetings/:id/no-show {outcome_note?}`: `meeting_done`, status `no_show`."
  @spec no_show(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def no_show(%Scope{} = scope, id, params, %DateTime{} = now),
    do: finish(scope, :no_show, id, params, now)

  defp finish(scope, verb, id, params, now) do
    params = Leads.stringify(params)

    with {:ok, m} <- fetch(scope, verb, id),
         :ok <- scheduled?(m) do
      {status, kind, label} = ending(verb)
      note = Leads.blank(params["outcome_note"])
      bump = if verb == :cancel, do: 1, else: 0
      attrs = %{status: status, outcome_note: note, sequence: m.sequence + bump}

      fn -> ended(scope, m, attrs, {verb, kind, label}, now) end
      |> Write.commit()
      |> answer(scope)
    end
  end

  defp ended(scope, m, attrs, {verb, kind, label}, now) do
    with {:ok, ended} <- Store.update(m, attrs) do
      labels = %{meeting_id: m.id, from_label: m.title, to_label: label, note: attrs.outcome_note}
      _event = Ledger.record(scope, m.lead, kind, labels, now)
      audit_change(scope, m, ended, now)
      :ok = Reminders.drop(m.id)
      told = if verb == :cancel, do: Notices.changed(scope, ended), else: []
      {:ok, ended, [told, events(m.lead, ended)]}
    end
  end

  defp ending(:cancel), do: {:cancelled, :meeting_cancelled, "Cancelled"}
  defp ending(:done), do: {:done, :meeting_done, "Done"}
  defp ending(:no_show), do: {:no_show, :meeting_done, "No-show"}

  defp scheduled?(%Meeting{status: :scheduled}), do: :ok

  defp scheduled?(%Meeting{status: status}),
    do: Leads.invalid("status", "This meeting is already #{status_words(status)}.")

  defp status_words(:cancelled), do: "cancelled"
  defp status_words(:done), do: "done"
  defp status_words(:no_show), do: "marked a no-show"

  # ── The clash, the stage offer ──────────────────────────────────────────────

  @doc """
  `POST /meetings/clash {lead_id, starts_at, ends_at, meeting_id?,
  meeting_kind?}`: `{clash: {words}?, stage_offer: {key, name, words}?}` —
  the offer (QP6-18) when `meeting_kind` is sent and the lead's pipeline
  has a later stage of that kind.
  """
  @spec clash(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def clash(%Scope{} = scope, params) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :read, params["lead_id"] || ""),
         {:ok, starts, ends} <- times(params) do
      {:ok,
       %{
         clash: Sheet.clash_for(scope, lead, starts, ends, Leads.blank(params["meeting_id"])),
         stage_offer: Sheet.stage_offer(lead, params["meeting_kind"])
       }}
    end
  end

  # ── ICS ─────────────────────────────────────────────────────────────────────

  @doc "`GET /meetings/:id/ics`: `{:ok, filename, text/calendar}` for staff and the customer."
  @spec ics(Scope.t(), term()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def ics(%Scope{} = scope, id) do
    with {:ok, m} <- fetch(scope, :read, id),
         do: {:ok, "meeting-#{m.id}.ics", Ics.for_meeting(m)}
  end

  @doc "**meeting**, as `scope` sees it (`Core.Meetings.Sheet`)."
  @spec view(Scope.t(), Meeting.t()) :: map()
  defdelegate view(scope, meeting), to: Sheet

  @doc false
  defdelegate clash_for(scope, lead, starts, ends, except_id), to: Sheet

  @doc "The stage a meeting kind offers (QP6-18), or `nil`."
  defdelegate stage_offer(lead, kind), to: Sheet

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp times(params) do
    with {:ok, starts} <- time(params["starts_at"], "starts_at", :required),
         {:ok, ends} <- time(params["ends_at"], "ends_at", :required) do
      if DateTime.compare(ends, starts) == :gt,
        do: {:ok, starts, ends},
        else: Leads.invalid("ends_at", "must be after it starts")
    end
  end

  defp time(value, field, required \\ :optional)
  defp time(nil, field, :required), do: {:error, {:missing, [String.to_existing_atom(field)]}}
  defp time(nil, _field, :optional), do: {:ok, nil}
  defp time("", field, required), do: time(nil, field, required)

  defp time(value, field, _required) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _bad -> Leads.invalid(field, "is not a time")
    end
  end

  defp time(_value, field, _required), do: Leads.invalid(field, "is not a time")

  # `[{user_id} | {contact_id} | {customer: true}]`, each once.
  defp attendees(_scope, _lead, nil), do: {:ok, []}

  defp attendees(scope, lead, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {a, i}, {:ok, acc} ->
      case attendee_attrs(scope, lead, Leads.stringify(a)) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, message} -> {:halt, Leads.invalid("attendees.#{i}", message)}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end)
  end

  defp attendees(_scope, _lead, _other), do: Leads.invalid("attendees", "is a list")

  defp attendee_attrs(_scope, _lead, %{"customer" => c}) when c in [true, "true"],
    do: {:ok, %{is_customer: true}}

  defp attendee_attrs(_scope, lead, %{"user_id" => id}) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{} <- Teams.get_open_member(lead.job.team_id, uuid) do
      {:ok, %{user_id: uuid}}
    else
      _other -> {:error, "isn't in this lead's team"}
    end
  end

  defp attendee_attrs(scope, _lead, %{"contact_id" => id}) when is_binary(id) do
    case ContactStore.get(Scope.organisation_id(scope), id) do
      nil -> {:error, "is not a contact"}
      %{merged_into_contact_id: nil} = c -> {:ok, %{contact_id: c.id}}
      merged -> {:ok, %{contact_id: merged.merged_into_contact_id}}
    end
  end

  defp attendee_attrs(_scope, _lead, _other),
    do: {:error, "is {user_id}, {contact_id} or {customer: true}"}

  defp stage(_lead, key) when key in [nil, ""], do: {:ok, nil}

  defp stage(lead, key) do
    case Enum.find(lead.pipeline_version.stages, &(&1.key == to_string(key))) do
      nil -> Leads.invalid("move_to_stage", "is not a stage of this lead's pipeline")
      stage -> {:ok, stage}
    end
  end

  defp events(lead, m),
    do: [Realtime.meeting_changed(lead, m.id), Realtime.lead_events("lead_updated", lead)]

  defp audit_change(scope, before, updated, now) do
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

  defp snapshot(m) do
    m
    |> Audit.snapshot(@audited)
    |> Map.merge(%{"lead_id" => m.lead_id})
  end

  defp answer({:ok, m}, scope), do: {:ok, view(scope, Store.reload(m))}
  defp answer(error, _scope), do: error
end
