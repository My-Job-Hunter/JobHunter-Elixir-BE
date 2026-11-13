defmodule Core.Meetings.Proposals do
  @moduledoc """
  Meetings an invitation proposes (AQ-09 §9, §11.4, QP9-12…14), and a
  person's *Confirm* · *Dismiss*.

  **Proposing**, inside the landing's (or the link's) transaction: an
  `.ics` part on a mail whose conversation is linked to a lead —
  when it lands, or when triage links it later (`on_link/4`) — is read by
  `Core.Meetings.Invite` and, by its `UID` on that lead:

  | The lead has | `REQUEST` | `CANCEL` |
  |---|---|---|
  | no meeting of that UID | a **proposed** meeting (`source: email_invite`, `from_message_id`, `proposal`); no reminders, no `meetings.scheduled`; the owner told (`meetings.proposed`) | nothing |
  | a proposed one | a higher `SEQUENCE` updates it in place | the cancel proposed (`change.cancel`) |
  | a scheduled one | a higher `SEQUENCE` with new times proposes the move (`change`) | the cancel proposed |
  | a done, cancelled or no-show one | nothing | nothing |

  A lower or equal `SEQUENCE` is a copy already read (a `CANCEL` may keep
  the sequence). Each proposal sends `meeting_changed` on `lead:` only.

  **Confirm** (`confirm/3`, whoever may change the lead's meetings): a
  proposed meeting becomes *scheduled* with P6's ledger row, reminders
  and `meetings.scheduled`; a proposed move is P6's reschedule, a proposed
  cancel P6's cancel; a proposed meeting whose invitation was cancelled
  is marked cancelled, telling nobody (nobody had it). Otherwise 409
  `meeting_not_proposed`. **Dismiss** (`dismiss/3`): a proposed meeting
  is deleted; a proposed change is dropped.
  """

  alias Core.Audit
  alias Core.Conversations.Eml
  alias Core.Leads.Ledger
  alias Core.Meetings
  alias Core.Meetings.{Invite, Notices, Reminders, Words}
  alias Core.Storage
  alias Core.Tasks.Write
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: ConversationStore
  alias Data.Meetings, as: Store
  alias Data.Meetings.Meeting
  alias Data.Scope

  # ── Proposing ───────────────────────────────────────────────────────────────

  @doc """
  The invitation in a mail just landed (`mail.calendar`), proposed on each
  of `leads`. Answers the realtime events.
  """
  @spec from_mail(Scope.t(), [map()], map(), map(), DateTime.t()) :: list()
  def from_mail(_scope, [], _message, _mail, _now), do: []
  def from_mail(_scope, _leads, _message, %{calendar: nil}, _now), do: []

  def from_mail(%Scope{} = scope, leads, message, %{calendar: text}, %DateTime{} = now)
      when is_binary(text) do
    for lead <- leads do
      case Invite.read(text, zone(lead)) do
        {:ok, invite} -> apply_invite(scope, lead, message, invite, now)
        :none -> []
      end
    end
  end

  def from_mail(_scope, _leads, _message, _mail, _now), do: []

  @doc """
  A conversation just linked to `lead` (triage, by hand, any rule): the
  invitations its mails carry, oldest first, proposed now (§9: "when it's
  linked, the proposal is made then"). Re-reads each mail's kept `.eml`.
  """
  @spec on_link(Scope.t(), map(), map(), DateTime.t()) :: list()
  def on_link(%Scope{} = scope, conversation, lead, %DateTime{} = now) do
    for m <- ConversationStore.messages([conversation.id]),
        m.source_media_id,
        is_nil(m.deleted_at),
        text = calendar(m.source_media_id),
        {:ok, invite} <- [Invite.read(text, zone(lead))] do
      apply_invite(scope, lead, m, invite, now)
    end
  end

  defp calendar(media_id) do
    with %{storage_key: key} <- Data.Files.get(media_id),
         {:ok, bytes} <- Storage.fetch(key),
         {:ok, %{calendar: text}} when is_binary(text) <- Eml.parse(bytes) do
      text
    else
      _none -> nil
    end
  end

  defp zone(lead), do: lead.profile.customer.timezone || "Etc/UTC"

  defp apply_invite(scope, lead, message, invite, now) do
    case Store.by_invite(lead.id, invite.uid) do
      nil ->
        if invite.method == :request, do: propose(scope, lead, message, invite, now), else: []

      %Meeting{status: :proposed} = m ->
        again(scope, m, message, invite, now)

      %Meeting{status: :scheduled} = m ->
        change(scope, m, message, invite, now)

      _past ->
        []
    end
  end

  defp propose(scope, lead, message, invite, now) do
    attrs =
      invite
      |> Map.take([
        :title,
        :meeting_kind,
        :platform,
        :join_url,
        :address,
        :starts_at,
        :ends_at,
        :time_zone
      ])
      |> Map.merge(%{
        organisation_id: lead.organisation_id,
        lead_id: lead.id,
        status: :proposed,
        source: :email_invite,
        from_message_id: message.id,
        proposal: proposal(invite, nil),
        created_by_user_id: Scope.user_id(scope)
      })

    case Store.create(attrs) do
      {:ok, m} ->
        :ok = attendees(m, lead, invite)
        m = Store.reload(m)
        {:ok, _audit} = Audit.record(scope, "created", m, after: snapshot(m), now: now)
        [Notices.proposed(scope, m), lead_event(m)]

      {:error, _unusable} ->
        []
    end
  end

  # The customer, and the organizer when they are a contact.
  defp attendees(m, lead, invite) do
    {:ok, _customer} = Store.add_attendee(%{meeting_id: m.id, is_customer: true})

    with email when is_binary(email) <- invite[:organizer_email],
         [contact | _rest] <- ContactStore.by_handles(lead.organisation_id, [{:email, email}]) do
      {:ok, _contact} = Store.add_attendee(%{meeting_id: m.id, contact_id: contact.id})
    end

    :ok
  end

  # The same UID on a proposed meeting: a newer request updates it; a cancel proposes the cancel.
  defp again(scope, m, message, invite, now) do
    case newer(m, invite) do
      :request ->
        attrs =
          invite
          |> Map.take([:title, :platform, :join_url, :address, :starts_at, :ends_at, :time_zone])
          |> Map.merge(%{from_message_id: message.id, proposal: proposal(invite, nil)})

        updated(scope, m, attrs, now)

      :cancel ->
        updated(
          scope,
          m,
          %{from_message_id: message.id, proposal: proposal(invite, cancel())},
          now
        )

      :old ->
        []
    end
  end

  # The same UID on a confirmed meeting: the move or the cancel, proposed; a
  # newer request at the same times only moves the sequence on.
  defp change(scope, m, message, invite, now) do
    case newer(m, invite) do
      :request ->
        if moved?(m, invite) do
          change = %{
            "starts_at" => DateTime.to_iso8601(invite.starts_at),
            "ends_at" => DateTime.to_iso8601(invite.ends_at),
            "cancel" => false
          }

          updated(
            scope,
            m,
            %{from_message_id: message.id, proposal: proposal(invite, change)},
            now
          )
        else
          {:ok, _quiet} =
            Store.update(m, %{proposal: Map.put(m.proposal || %{}, "sequence", invite.sequence)})

          []
        end

      :cancel ->
        updated(
          scope,
          m,
          %{from_message_id: message.id, proposal: proposal(invite, cancel())},
          now
        )

      :old ->
        []
    end
  end

  # A request with a higher SEQUENCE, a cancel not below it (and not proposed
  # already), or a copy already read.
  defp newer(m, invite) do
    held = (m.proposal || %{})["sequence"] || 0

    cond do
      invite.method == :request and invite.sequence > held -> :request
      invite.method == :cancel and invite.sequence >= held and not cancel?(m) -> :cancel
      true -> :old
    end
  end

  defp updated(scope, m, attrs, now) do
    case Store.update(m, attrs) do
      {:ok, updated} ->
        Meetings.audit_change(scope, m, updated, now)
        [Notices.proposed(scope, updated), lead_event(updated)]

      {:error, _unusable} ->
        []
    end
  end

  defp moved?(m, invite),
    do:
      DateTime.compare(m.starts_at, invite.starts_at) != :eq or
        DateTime.compare(m.ends_at, invite.ends_at) != :eq

  defp cancel?(%{proposal: %{"change" => %{"cancel" => true}}}), do: true
  defp cancel?(_m), do: false

  defp cancel, do: %{"starts_at" => nil, "ends_at" => nil, "cancel" => true}

  defp proposal(invite, change) do
    %{
      "organizer" => invite.organizer,
      "method" => if(invite.method == :cancel, do: "CANCEL", else: "REQUEST"),
      "uid" => invite.uid,
      "sequence" => invite.sequence,
      "change" => change
    }
  end

  defp lead_event(m),
    do: {"lead:" <> m.lead_id, "meeting_changed", %{lead: m.lead_id, meeting: m.id}}

  # ── Confirm, Dismiss ────────────────────────────────────────────────────────

  @doc "`POST /meetings/:id/confirm`: answers the **meeting**."
  @spec confirm(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def confirm(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, m} <- Meetings.fetch(scope, :confirm, id),
         {:ok, what} <- pending(m) do
      fn -> confirmed(scope, m, what, now) end
      |> Write.commit()
      |> case do
        {:ok, m} -> {:ok, Meetings.view(scope, Store.reload(m))}
        error -> error
      end
    end
  end

  defp confirmed(scope, m, :proposed, now) do
    with {:ok, scheduled} <- Store.update(m, %{status: :scheduled}) do
      labels = %{
        meeting_id: m.id,
        to_label: scheduled.title,
        from_label: Words.at(scheduled.starts_at, scheduled.time_zone)
      }

      _event = Ledger.record(scope, m.lead, :meeting_scheduled, labels, now)
      Meetings.audit_change(scope, m, scheduled, now)
      :ok = Reminders.plan(scheduled, now)
      {:ok, scheduled, [Notices.scheduled(scope, scheduled), Meetings.events(m.lead, scheduled)]}
    end
  end

  defp confirmed(scope, m, :withdrawn, now) do
    with {:ok, ended} <- Store.update(m, %{status: :cancelled, proposal: settled(m)}) do
      Meetings.audit_change(scope, m, ended, now)
      {:ok, ended, [lead_event(ended)]}
    end
  end

  defp confirmed(scope, m, {:move, starts, ends}, now) do
    with {:ok, m} <- Store.update(m, %{proposal: settled(m)}) do
      Meetings.apply_reschedule(
        scope,
        m,
        %{starts_at: starts, ends_at: ends, sequence: m.sequence + 1},
        now
      )
    end
  end

  defp confirmed(scope, m, :cancel, now) do
    with {:ok, m} <- Store.update(m, %{proposal: settled(m)}) do
      Meetings.apply_cancel(scope, m, now)
    end
  end

  @doc "`POST /meetings/:id/dismiss`: `{:ok, :dismissed}`."
  @spec dismiss(Scope.t(), term(), DateTime.t()) :: {:ok, :dismissed} | {:error, term()}
  def dismiss(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, m} <- Meetings.fetch(scope, :dismiss, id),
         {:ok, what} <- pending(m),
         {:ok, _m} <- Write.commit(fn -> dismissed(scope, m, what, now) end),
         do: {:ok, :dismissed}
  end

  defp dismissed(scope, m, what, now) when what in [:proposed, :withdrawn] do
    with {:ok, gone} <- Store.delete(m) do
      {:ok, _audit} = Audit.record(scope, "deleted", m, before: snapshot(m), now: now)
      {:ok, gone, [lead_event(m)]}
    end
  end

  defp dismissed(scope, m, _change, now) do
    with {:ok, kept} <- Store.update(m, %{proposal: settled(m)}) do
      Meetings.audit_change(scope, m, kept, now)
      {:ok, kept, [lead_event(kept)]}
    end
  end

  # What a confirm or a dismiss acts on, or 409 `meeting_not_proposed`.
  defp pending(%Meeting{status: :proposed} = m),
    do: {:ok, if(cancel?(m), do: :withdrawn, else: :proposed)}

  defp pending(%Meeting{status: :scheduled, proposal: %{"change" => %{"cancel" => true}}}),
    do: {:ok, :cancel}

  defp pending(%Meeting{
         status: :scheduled,
         proposal: %{"change" => %{"starts_at" => s, "ends_at" => e}}
       })
       when is_binary(s) and is_binary(e) do
    {:ok, starts, _offset} = DateTime.from_iso8601(s)
    {:ok, ends, _offset} = DateTime.from_iso8601(e)
    {:ok, {:move, starts, ends}}
  end

  defp pending(m), do: {:error, {:meeting_not_proposed, m}}

  defp settled(m), do: Map.put(m.proposal || %{}, "change", nil)

  defp snapshot(m),
    do:
      m
      |> Audit.snapshot([:title, :status, :starts_at, :ends_at, :time_zone, :source, :proposal])
      |> Map.merge(%{"lead_id" => m.lead_id, "from_message_id" => m.from_message_id})
end
