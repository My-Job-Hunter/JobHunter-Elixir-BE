defmodule Core.Conversations.Match do
  @moduledoc """
  AQ-09 §7's matching, beyond P6's sender handle: the rules a forwarded
  mail (or an upload) meets when its conversation has no link yet, in
  order — the first that decides wins (`link/5`):

  1. **Reply headers:** a message the mail's `In-Reply-To` or `References`
     names sits in a conversation of the team with leads → those leads,
     `headers · sure` (the conversation it joins had none).
  2. **The receiving inbox:** the channel names the customer (and the
     profile, when it serves exactly one); the other side is a contact on
     **exactly one** open lead of that customer in the team →
     `receiving_inbox · likely`.
  3. **The sender's handle** on exactly one open lead of the team (P6's
     rule, unchanged) → `sender_handle · likely`.
  4. **The sender's domain** never links: its leads are triage's
     candidates (`candidates/3`).
  5. **A platform's notice** to a receiving channel: company and title
     from the subject (`Core.Conversations.Platforms`), the receiving
     customer's open leads applied (or made) in the last 60 days, in the
     team → one: `platform_notice · likely`; several: triage, with them as
     candidates.

  `team/4` picks a forwarded mail's team among the customer's: the one
  holding the thread, else the one of rule 2's or rule 5's single lead,
  else the customer's first. Reads only; the links are
  `Core.Conversations.Record`'s.
  """

  alias Core.Conversations.Platforms
  alias Core.Leads.Words
  alias Data.Contacts, as: ContactStore
  alias Data.Conversations.Match, as: Store

  @days 60

  @doc "Which rule links: `{method, confidence, [lead_id]}`, or `nil` (triage)."
  @spec link(map(), map(), map(), map() | nil, DateTime.t()) :: {atom(), atom(), [binary()]} | nil
  def link(c, sender, mail, channel, %DateTime{} = now) do
    Enum.find_value(
      [
        fn -> headers(c, mail) end,
        fn -> channel && one(receiving_inbox(c, channel, sender.contacts), :receiving_inbox) end,
        fn -> one(sender_handle(c, sender.contacts), :sender_handle) end,
        fn -> channel && one(platform_notice(c.team_id, channel, mail, now), :platform_notice) end
      ],
      & &1.()
    )
  end

  defp one([lead_id], method), do: {method, :likely, [lead_id]}
  defp one(_none_or_several, _method), do: nil

  # Rule 1: the leads of the conversations holding the referenced messages,
  # the nearest parent's first.
  defp headers(c, mail) do
    asked = Enum.reject([mail.in_reply_to | Enum.reverse(mail.references)], &is_nil/1)
    by_rfc = Store.leads_of_messages(c.organisation_id, c.team_id, asked)

    case Enum.find_value(asked, &Map.get(by_rfc, &1)) do
      [_ | _] = ids -> {:headers, :sure, ids}
      _none -> nil
    end
  end

  @doc "Rule 2's leads: the receiving customer's open leads in the team holding `contact_ids`."
  @spec receiving_inbox(map(), map(), [binary()]) :: [binary()]
  def receiving_inbox(c, channel, contact_ids) do
    channel.customer_id
    |> Store.customer_leads_holding(contact_ids,
      team_id: c.team_id,
      profile_id: profile_id(channel)
    )
    |> Enum.map(&elem(&1, 0))
  end

  defp sender_handle(c, contact_ids) do
    c.team_id
    |> ContactStore.open_leads_holding(contact_ids, nil)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  @doc "Rule 5's leads: the receiving customer's recent open leads a platform's notice names."
  @spec platform_notice(binary() | nil, map(), map(), DateTime.t()) :: [binary()]
  def platform_notice(team_id, channel, mail, now) do
    {_name, address} = mail.from

    with platform when not is_nil(platform) <- Platforms.platform(address),
         %{} = notice <- Platforms.notice(mail.subject) do
      channel.customer_id
      |> Store.recent_leads(DateTime.add(now, -@days, :day), team_id: team_id)
      |> Enum.filter(&Platforms.fits?(notice, &1))
      |> Enum.map(& &1.id)
    else
      _no_notice -> []
    end
  end

  @doc """
  A forwarded mail's team among its channel's customer's: the thread's,
  else rule 2's or rule 5's single lead's, else the first the customer
  joined. `nil` for a customer no team serves.
  """
  @spec team(map(), map(), [binary()], DateTime.t()) :: binary() | nil
  def team(channel, mail, contact_ids, %DateTime{} = now) do
    teams =
      channel.customer.customer_teams
      |> Enum.sort_by(&{Date.to_gregorian_days(&1.since_on), &1.id})
      |> Enum.map(& &1.team_id)

    asked = Enum.reject([mail.in_reply_to | mail.references], &is_nil/1)

    List.first(Store.teams_holding(channel.customer.organisation_id, teams, asked)) ||
      single_team(
        Store.customer_leads_holding(channel.customer_id, contact_ids,
          profile_id: profile_id(channel)
        ),
        teams
      ) || platform_team(channel, mail, now, teams) || List.first(teams)
  end

  defp single_team([{_lead, team_id}], teams), do: if(team_id in teams, do: team_id)
  defp single_team(_none_or_several, _teams), do: nil

  defp platform_team(channel, mail, now, teams) do
    case platform_notice(nil, channel, mail, now) do
      [lead_id] ->
        Enum.find_value(
          Store.recent_leads(channel.customer_id, DateTime.add(now, -@days, :day), []),
          &(&1.id == lead_id and &1.team_id in teams and &1.team_id)
        )

      _none_or_several ->
        nil
    end
  end

  @doc "The profile a channel serves, when it serves exactly one; else `nil`."
  @spec profile_id(map() | nil) :: binary() | nil
  def profile_id(%{profile_channels: [%{profile_id: id}]}), do: id
  def profile_id(_channel), do: nil

  @doc "The profiles a channel serves (with their owners), for the triage notice (QP9-15)."
  @spec profiles(map() | nil) :: [map()]
  def profiles(%{profile_channels: links}) when is_list(links) do
    for %{profile: %{archived_at: nil} = p} <- links, do: p
  end

  def profiles(_channel), do: []

  # ── Triage's candidates (rules 4 and 5) ─────────────────────────────────────

  @doc """
  A triage item's candidates beyond P6's: the team's open leads at the
  sender's domain ("The sender's domain corvid.example is Corvid
  Security's"), and the leads a platform's notice may mean ("Indeed's
  notice names Senior Golang Engineer · Corvid Security"). `[{lead_id,
  why}]`, the conversation's customer's alone when it has one.
  """
  @spec candidates(map(), list(), DateTime.t()) :: [{binary(), String.t()}]
  def candidates(c, messages, %DateTime{} = now) do
    inbound = Enum.filter(messages, &(&1.direction == :in))

    addresses =
      inbound |> Enum.map(&address(&1.from_text)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    by_domain =
      for domain <-
            addresses
            |> Enum.map(&Platforms.company_domain/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq(),
          {lead_id, company} <-
            Store.leads_at_domain(c.organisation_id, c.team_id, domain, c.customer_id),
          do: {lead_id, "The sender's domain #{domain} is #{company}'s"}

    by_domain ++ notice_candidates(c, addresses, now)
  end

  defp notice_candidates(%{customer_id: nil}, _addresses, _now), do: []

  defp notice_candidates(c, addresses, now) do
    with address when is_binary(address) <- Enum.find(addresses, &Platforms.platform/1),
         %{} = notice <- Platforms.notice(c.subject) do
      platform = address |> Platforms.platform() |> Words.value()

      for lead <-
            Store.recent_leads(c.customer_id, DateTime.add(now, -@days, :day), team_id: c.team_id),
          Platforms.fits?(notice, lead) do
        names = Enum.reject([lead.title, lead.company], &is_nil/1) |> Enum.join(" · ")
        {lead.id, "#{platform}'s notice names #{names}"}
      end
    else
      _none -> []
    end
  end

  @doc ~S"""
  The address in a header's text.

      iex> Core.Conversations.Match.address("Omar Haddad <omar.haddad@corvid.example>")
      "omar.haddad@corvid.example"
      iex> Core.Conversations.Match.address(nil)
      nil
  """
  @spec address(String.t() | nil) :: String.t() | nil
  def address(text) when is_binary(text) do
    case Regex.run(~r/[^\s<>"',;]+@[^\s<>"',;]+/, text) do
      [address] -> String.downcase(address)
      nil -> nil
    end
  end

  def address(_text), do: nil
end
