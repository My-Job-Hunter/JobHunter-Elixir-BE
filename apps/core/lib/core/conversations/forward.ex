defmodule Core.Conversations.Forward do
  @moduledoc """
  A forwarded mail landed (AQ-09 §6.2, §7): what `Core.Inbound` hands on
  once it knows the receiving channel, read the mail and found it new.
  It runs **as the system for the channel's organisation**, in one
  transaction:

  1. **The team**, among the customer's (`Core.Conversations.Match.team/4`):
     the thread's, else the one of the single lead the receiving inbox or
     a platform's notice points at, else the customer's first.
  2. **The raw mail kept** as the message's `.eml` media (QP9-20), as an
     upload's is.
  3. **P6's landing** (`Core.Conversations.Inbox.land/8`) with the
     receiving channel and `captured_via: forward`.
  4. **The channel's** `last_inbound_at` moved, and Gmail's forwarding
     check cleared: a real mail came through.

  Answers `{:ok, message}` (the mail's message), or why it couldn't land.
  """

  alias Core.Conversations.{Inbox, Match}
  alias Core.Media
  alias Core.Tasks.Write
  alias Data.Channels
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations, as: Store
  alias Data.Inbound
  alias Data.Scope

  @doc "Lands `mail` (parsed from `raw`) through `channel`, keyed `key`."
  @spec land(Scope.t(), map(), binary(), map(), String.t(), DateTime.t()) ::
          {:ok, Data.Conversations.Message.t()} | {:error, term()}
  def land(%Scope{} = scope, channel, raw, mail, key, %DateTime{} = now) do
    org = Scope.organisation_id(scope)

    case Match.team(channel, mail, contacts(org, channel, mail), now) do
      nil ->
        {:error, :no_team}

      team_id ->
        team = Data.Teams.get(org, team_id)
        Write.commit(fn -> landed(scope, team, channel, raw, mail, key, now) end)
    end
  end

  defp landed(scope, team, channel, raw, mail, key, now) do
    with {:ok, media} <- Media.store_email(scope, raw, now),
         {:ok, c, events} <-
           Inbox.land(scope, team, nil, media, mail, key, now, channel: channel, via: :forward) do
      :ok = Channels.mark_inbound(channel.id, now)
      :ok = Inbound.clear_confirmations(channel.id, now)
      {:ok, Store.message_by_key(c.organisation_id, key), events}
    end
  end

  # The other side's contacts, for picking the team: the recipients when
  # the customer wrote it (a BCC'd reply), else the sender.
  defp contacts(org, channel, %{from: {_name, from}} = mail) do
    own =
      [channel.customer.email, channel.handle_normalized]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)

    addresses =
      if from in own,
        do: Enum.map(mail.to ++ mail.cc, &elem(&1, 1)),
        else: [from]

    addresses
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&ContactStore.by_handles(org, [{:email, &1}]))
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end
end
