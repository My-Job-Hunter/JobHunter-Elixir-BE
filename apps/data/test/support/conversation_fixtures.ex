defmodule Data.Fixtures.Conversations do
  @moduledoc """
  P6's fixtures (AQ-06 §14), reached through `Data.Fixtures`
  (`contact_fixture/2`, `conversation_fixture/2`, `message_fixture/2`,
  `meeting_fixture/2`). Like the rest they take a scope and write through
  `Data.*`, so a row that could not exist in production cannot be built: a
  conversation is in a team, linked only to that team's leads; a message's
  author key is its kind's; a meeting is a lead's.
  """

  alias Data.Contacts
  alias Data.Conversations
  alias Data.Meetings
  alias Data.Scope

  @doc """
  A contact of the scope's organisation: `name:`, `title:`, `company:` (a
  struct), `handles:` (`[{kind, value}]`), `source:`, `time_zone:`.
  """
  def contact_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    org = Scope.organisation_id(scope)

    {:ok, contact} =
      Contacts.create(%{
        organisation_id: org,
        name: attrs[:name] || "Contact #{System.unique_integer([:positive])}",
        title: attrs[:title],
        company_id: attrs[:company] && attrs[:company].id,
        time_zone: attrs[:time_zone],
        source: attrs[:source] || :manual,
        created_by_user_id: Scope.user_id(scope)
      })

    for {kind, value} <- attrs[:handles] || [] do
      {:ok, _handle} =
        Contacts.add_handle(%{
          organisation_id: org,
          contact_id: contact.id,
          kind: kind,
          value: value
        })
    end

    Contacts.reload(contact)
  end

  @doc """
  A conversation: `lead:` (linked, by hand, sure; in the lead's team, about
  its customer) or `team:` (triage); `platform:` (email), `subject:`,
  `external_thread_id:`, `match_method:`, `confidence:`, `ignored_at:`.
  """
  def conversation_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    lead = attrs[:lead] && Data.Leads.reload(attrs[:lead])

    {:ok, c} =
      %{organisation_id: Scope.organisation_id(scope), platform: :email}
      |> Map.merge(Map.take(attrs, [:platform, :subject, :external_thread_id, :ignored_at]))
      |> Map.merge(where(scope, lead, attrs))
      |> Conversations.create()

    if lead, do: link(scope, c, lead, attrs)
    Conversations.reload(c)
  end

  # The team and the customer: the lead's, else as named.
  defp where(_scope, %{} = lead, _attrs),
    do: %{team_id: lead.job.team_id, customer_id: lead.profile.customer_id}

  defp where(scope, nil, attrs) do
    %{
      team_id: id(attrs[:team]) || Data.Fixtures.default_team(scope),
      customer_id: id(attrs[:customer])
    }
  end

  defp link(scope, c, lead, attrs) do
    {:ok, _linked} =
      Conversations.link(%{
        conversation_id: c.id,
        lead_id: lead.id,
        match_method: attrs[:match_method] || :by_hand,
        confidence: attrs[:confidence] || :sure,
        linked_by_user_id: Scope.user_id(scope)
      })
  end

  defp id(nil), do: nil
  defp id(%{id: id}), do: id

  @doc """
  A message of `conversation:` — by `contact:` (inbound), else by the
  scope's person (outbound) — with `direction:`, `from_kind:`, `body_text:`,
  `sent_at:`, `parent:` (a message), `captured_via:` (`manual`),
  `is_internal:`, `rfc_message_id:`, `in_reply_to:`, `references:`,
  `idempotency_key:`, `from_text:`, `to_text:`.
  """
  def message_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    c = attrs[:conversation] || conversation_fixture(scope, Map.take(attrs, [:lead, :team]))
    contact = attrs[:contact]
    kind = attrs[:from_kind] || if(contact, do: :contact, else: :user)

    {:ok, m} =
      %{
        organisation_id: c.organisation_id,
        conversation_id: c.id,
        direction: if(kind == :contact, do: :in, else: :out),
        is_internal: false,
        from_kind: kind,
        sent_at: DateTime.utc_now(),
        body_text: "Message #{System.unique_integer([:positive])}",
        references: [],
        captured_via: :manual,
        created_by_user_id: Scope.user_id(scope)
      }
      |> Map.merge(author(scope, kind, contact, attrs))
      |> Map.merge(
        Map.take(attrs, ~w(direction is_internal to_text sent_at body_text rfc_message_id
                           in_reply_to references captured_via idempotency_key)a)
      )
      |> Map.put(:parent_message_id, id(attrs[:parent]))
      |> Conversations.insert_message()

    if contact, do: :ok = Conversations.add_participant(c.id, contact.id)
    Conversations.touch(c.id, m.sent_at)
    Data.Repo.preload(m, [:from_contact, from_user: [person: :photo], attachments: [:media]])
  end

  defp author(_scope, :contact, contact, attrs),
    do: %{from_contact_id: id(contact), from_text: attrs[:from_text]}

  defp author(scope, :user, _contact, attrs),
    do: %{from_user_id: id(attrs[:user]) || Scope.user_id(scope), from_text: attrs[:from_text]}

  defp author(_scope, :text, _contact, attrs),
    do: %{from_text: attrs[:from_text] || "Someone <someone@example.com>"}

  defp author(_scope, _customer, _contact, attrs), do: %{from_text: attrs[:from_text]}

  @doc """
  A meeting of `lead:`: `title:`, `meeting_kind:` (`technical`),
  `platform:` (`google_meet`), `starts_at:` (tomorrow), `ends_at:` (an
  hour later), `time_zone:` (`Europe/Berlin`), `status:`, `sequence:`,
  `join_url:`, `attendees:` (`[{:user, u} | {:contact, c} | :customer]`).
  """
  def meeting_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    lead = attrs[:lead] || raise ArgumentError, "a meeting needs lead:"
    starts = attrs[:starts_at] || DateTime.add(DateTime.utc_now(), 86_400, :second)

    {:ok, m} =
      %{
        organisation_id: lead.organisation_id,
        lead_id: lead.id,
        title: "Technical interview",
        meeting_kind: :technical,
        platform: :google_meet,
        join_url: "https://meet.google.com/abc-defg-hij",
        starts_at: starts,
        ends_at: DateTime.add(starts, 3600, :second),
        time_zone: "Europe/Berlin",
        status: :scheduled,
        sequence: 0,
        created_by_user_id: Scope.user_id(scope)
      }
      |> Map.merge(
        Map.take(
          attrs,
          ~w(title meeting_kind platform join_url ends_at time_zone status sequence)a
        )
      )
      |> Meetings.create()

    for a <- attrs[:attendees] || [],
        do: {:ok, _attendee} = Meetings.add_attendee(Map.put(attendee(a), :meeting_id, m.id))

    Meetings.reload(m)
  end

  defp attendee({:user, user}), do: %{user_id: user.id}
  defp attendee({:contact, contact}), do: %{contact_id: contact.id}
  defp attendee(:customer), do: %{is_customer: true}
end
