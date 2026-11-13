defmodule Core.InboundTest do
  @moduledoc """
  AQ-09 §6–§8 through the intake (`Core.Inbound.dev/3`, the webhook's own
  path with `provider: dev`): every matching rule of §7, the BCC'd reply
  as *out*, never twice (the provider's retry, the same Message-ID by
  another route, an upload after a forward), an unknown address and an
  unreadable mail logged and answered, Gmail's confirmation kept on the
  channel and never filed, triage told with the receiving profile, and
  the 30-day sweep. The made-up mails are `priv/eml/`'s.
  """

  use Core.CoreCase, async: true

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.{Inbox, Triage}
  alias Core.Customers.Channels
  alias Core.Inbound
  alias Data.Inbound.InboundMessage
  alias Data.Scope

  @now ~U[2026-11-12 09:00:00.000000Z]
  @applied ~U[2026-11-01 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)

    channel =
      channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com", label: "Gmail")

    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    juniper = company_fixture(c.org, name: "Juniper Edge")

    corvid =
      company_fixture(c.org, name: "Corvid Security", website_url: "https://corvidsec.example")

    juniper_job = job_fixture(fiza, team: c.backend, title: "Platform Engineer", company: juniper)

    corvid_job =
      job_fixture(fiza, team: c.backend, title: "Senior Golang Engineer", company: corvid)

    juniper_lead =
      lead_fixture(fiza, job: juniper_job, profile: c.golang, as: :apply, applied_at: @applied)

    corvid_lead =
      lead_fixture(fiza, job: corvid_job, profile: c.golang, as: :apply, applied_at: @applied)

    mei =
      contact_fixture(fiza,
        name: "Mei Chen",
        company: juniper,
        handles: [{:email, "mei.chen@juniperedge.example"}]
      )

    omar =
      contact_fixture(fiza,
        name: "Omar Haddad",
        company: corvid,
        handles: [{:email, "omar.haddad@corvid.example"}]
      )

    Map.merge(c, %{
      fiza_scope: fiza,
      channel: Data.Channels.reload(channel),
      juniper_lead: juniper_lead,
      corvid_lead: corvid_lead,
      corvid_job: corvid_job,
      juniper_job: juniper_job,
      mei: mei,
      omar: omar
    })
  end

  defp eml(name), do: File.read!(Path.expand("../../priv/eml/" <> name, __DIR__))

  defp deliver(c, name_or_text, to \\ nil) do
    text = if String.ends_with?(name_or_text, ".eml"), do: eml(name_or_text), else: name_or_text
    to = to || Inbound.address(c.channel.inbound_token)
    Inbound.dev(Scope.system(), %{"to" => to, "eml" => text}, @now)
  end

  defp contact_on(c, lead, contact),
    do:
      {:ok, _} =
        LeadLinks.link(
          c.fiza_scope,
          lead.id,
          %{"contact_id" => contact.id, "role" => "recruiter"},
          @now
        )

  defp links(conversation_id) do
    for l <- Repo.all(Data.Conversations.ConversationLead),
        l.conversation_id == conversation_id,
        do: {l.lead_id, l.match_method, l.confidence}
  end

  defp log, do: Repo.all(InboundMessage) |> Enum.sort_by(& &1.received_at)

  defp told(kind),
    do:
      for(n <- Repo.all(Data.Notifications.Notification), n.notification_kind_key == kind, do: n)

  test "a reply on a thread: thread-2 delivered joins thread-1's conversation on the lead, kept as its .eml",
       c do
    media = eml_media(c.fiza_scope, "thread-1.eml")

    {:ok, {:created, one}} =
      Inbox.eml(
        c.fiza_scope,
        %{"media_id" => media.id, "team_id" => c.backend.id, "lead_id" => c.juniper_lead.id},
        @now
      )

    assert {:ok, %{outcome: :landed, message_id: id, conversation_id: cid}} =
             deliver(c, "thread-2.eml")

    assert cid == one.conversation.id
    message = Repo.get!(Data.Conversations.Message, id)
    assert message.captured_via == :forward and message.direction == :in

    source = Repo.get!(Data.Files.Media, message.source_media_id)
    assert source.media_kind == :eml and source.content_type == "message/rfc822"
    assert {:ok, bytes} = Core.Storage.fetch(source.storage_key)
    assert bytes == eml("thread-2.eml")

    assert [%{outcome: :landed, message_id: ^id, provider: :dev, channel_id: channel_id}] = log()
    assert channel_id == c.channel.id
    assert Data.Channels.reload(c.channel).last_inbound_at == @now
  end

  test "rule 1, reply headers: joining a triage conversation, the parent's leads are copied (headers · sure)",
       c do
    media = eml_media(c.fiza_scope, "thread-1.eml")

    {:ok, _} =
      Inbox.eml(
        c.fiza_scope,
        %{"media_id" => media.id, "team_id" => c.backend.id, "lead_id" => c.juniper_lead.id},
        @now
      )

    assert {:ok, %{outcome: :landed, conversation_id: triage}} = deliver(c, "stranger-corvid.eml")
    assert links(triage) == []

    reply = """
    Message-ID: <20261107100000.lena-2@corvid.example>
    In-Reply-To: <20261106093000.lena-1@corvid.example>
    References: <20261102101500.mei-1@juniperedge.example> <20261106093000.lena-1@corvid.example>
    Date: Sat, 07 Nov 2026 10:00:00 +0000
    From: Someone <someone@elsewhere.example>
    To: Tanweer <tanweer@example.com>
    Subject: Re: Security engineering at Corvid

    Adding the Juniper thread for context.
    """

    assert {:ok, %{outcome: :landed, conversation_id: ^triage}} = deliver(c, reply)
    assert links(triage) == [{c.juniper_lead.id, :headers, :sure}]
  end

  test "rule 2, the receiving inbox: a contact on one lead of Tanweer's and one of Naveed's lands on Tanweer's",
       c do
    naveed_profile = profile_fixture(c.naveed, title: "Elixir backend")

    naveed_lead =
      lead_fixture(c.fiza_scope, job: c.juniper_job, profile: naveed_profile, as: :apply)

    contact_on(c, c.juniper_lead, c.mei)
    contact_on(c, naveed_lead, c.mei)

    mail = """
    Message-ID: <20261108090000.mei-5@juniperedge.example>
    Date: Sun, 08 Nov 2026 09:00:00 +0800
    From: Mei Chen <mei.chen@juniperedge.example>
    To: Tanweer <tanweer@example.com>
    Subject: Next steps

    Hi Tanweer, the team would like to move forward.
    """

    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, mail)
    assert links(cid) == [{c.juniper_lead.id, :receiving_inbox, :likely}]

    # P6 alone (an upload, no receiving inbox): two open leads hold Mei, so triage.
    Repo.delete_all(Data.Conversations.Conversation)
    media = eml_media(c.fiza_scope, mail)

    assert {:ok, {:created, %{landed: "triage"}}} =
             Inbox.eml(c.fiza_scope, %{"media_id" => media.id, "team_id" => c.backend.id}, @now)
  end

  test "rule 3, the sender's handle: on a lead of a profile the channel doesn't serve, P6's rule links it",
       c do
    other_profile = profile_fixture(c.tanweer, title: "Platform")
    lead = lead_fixture(c.fiza_scope, job: c.juniper_job, profile: other_profile, as: :apply)
    contact_on(c, lead, c.mei)

    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, "thread-1.eml")
    assert links(cid) == [{lead.id, :sender_handle, :likely}]
  end

  test "rule 4, the sender's domain: a stranger at corvid.example goes to triage with Corvid's lead as a candidate; free mail names nobody",
       c do
    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, "stranger-corvid.eml")
    assert links(cid) == []

    {:ok, page} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert [item] = page.items
    assert [%{lead: %{id: lead_id}, why: why}] = item.candidates
    assert lead_id == c.corvid_lead.id
    assert why == "The sender's domain corvid.example is Corvid Security's"
    assert item.profile == %{id: c.golang.id, title: "Golang backend"}
    assert item.customer == %{id: c.tanweer.id, display_name: "Tanweer"}

    free =
      String.replace(eml("stranger-corvid.eml"), "lena.park@corvid.example", "lena@gmail.com")

    free = String.replace(free, "lena-1@corvid", "lena-9@corvid")
    assert {:ok, %{outcome: :landed}} = deliver(c, free)
    {:ok, page} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert Enum.count(page.items, &(&1.candidates == [])) == 1
  end

  test "rule 5, a platform's notice: Indeed's links the one recent lead it names; two that fit go to triage",
       c do
    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, "indeed-notice.eml")
    assert links(cid) == [{c.corvid_lead.id, :platform_notice, :likely}]

    Repo.delete_all(Data.Conversations.Conversation)
    Repo.delete_all(InboundMessage)

    lead_fixture(c.fiza_scope,
      job:
        job_fixture(c.fiza_scope,
          team: c.backend,
          title: "Senior Golang Engineer",
          company: Repo.get!(Data.Companies.Company, c.corvid_job.company_id)
        ),
      profile: profile_fixture(c.tanweer, title: "Go, again"),
      as: :apply,
      applied_at: @applied
    )

    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, "indeed-notice.eml")
    assert links(cid) == []
    {:ok, page} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert [%{candidates: [_, _] = candidates}] = page.items

    assert Enum.all?(
             candidates,
             &(&1.why == "Indeed's notice names Senior Golang Engineer · Corvid Security")
           )
  end

  test "a platform's notice older than 60 days names nothing", c do
    Repo.update_all(Data.Leads.Lead,
      set: [
        applied_at: ~U[2026-08-01 09:00:00.000000Z],
        inserted_at: ~U[2026-08-01 09:00:00.000000Z]
      ]
    )

    assert {:ok, %{outcome: :landed, conversation_id: cid}} = deliver(c, "indeed-notice.eml")
    assert links(cid) == []
  end

  test "the BCC'd reply: Tanweer's own mail lands on its thread as out, from the customer", c do
    media = eml_media(c.fiza_scope, "thread-1.eml")

    {:ok, {:created, one}} =
      Inbox.eml(
        c.fiza_scope,
        %{"media_id" => media.id, "team_id" => c.backend.id, "lead_id" => c.juniper_lead.id},
        @now
      )

    assert {:ok, %{outcome: :landed}} = deliver(c, "thread-2.eml")

    assert {:ok, %{outcome: :landed, message_id: id, conversation_id: cid}} =
             deliver(c, "bcc-reply.eml")

    assert cid == one.conversation.id
    assert %{direction: :out, from_kind: :customer} = Repo.get!(Data.Conversations.Message, id)
  end

  test "never twice: the provider's retry adds nothing, the same Message-ID by another route is a duplicate, an upload after says already",
       c do
    assert {:ok, %{outcome: :landed, message_id: id}} = deliver(c, "thread-1.eml")
    assert {:ok, %{outcome: :duplicate, message_id: ^id}} = deliver(c, "thread-1.eml")
    assert length(log()) == 1

    other_route = "Tanweer <#{Inbound.address(c.channel.inbound_token)}>"

    assert {:ok, %{outcome: :duplicate, message_id: ^id}} =
             deliver(c, "thread-1.eml", other_route)

    assert [%{outcome: :landed}, %{outcome: :duplicate, message_id: ^id}] = log()

    media = eml_media(c.fiza_scope, "thread-1.eml")

    assert {:ok, {:already, _}} =
             Inbox.eml(c.fiza_scope, %{"media_id" => media.id, "team_id" => c.backend.id}, @now)

    assert Repo.aggregate(Data.Conversations.Message, :count) == 1
  end

  test "an unknown address, an archived channel's and an unreadable mail are answered and logged",
       c do
    assert {:ok, %{outcome: :unknown_address, message_id: nil, conversation_id: nil}} =
             deliver(c, "thread-1.eml", "in+zzzzzzzzzz@inbound.autoqare.local")

    assert {:ok, %{outcome: :unknown_address}} =
             deliver(c, "thread-1.eml", "someone@elsewhere.example")

    assert {:ok, %{outcome: :unreadable}} = deliver(c, "this is not an email")

    assert [
             %{
               outcome: :unknown_address,
               organisation_id: nil,
               channel_id: nil,
               to_address: "in+zzzzzzzzzz@inbound.autoqare.local"
             },
             %{outcome: :unknown_address},
             %{outcome: :unreadable, channel_id: channel_id}
           ] = log()

    assert channel_id == c.channel.id
    {:ok, _} = Data.Channels.archive(c.channel, @now)
    assert {:ok, %{outcome: :unknown_address}} = deliver(c, "thread-2.eml")
    assert Repo.aggregate(Data.Conversations.Message, :count) == 0
  end

  test "Gmail's confirmation: the code and link on the channel, the owners and the customer told, never a conversation; the first real mail clears it",
       c do
    assert {:ok, %{outcome: :gmail_confirmation, message_id: nil}} =
             deliver(c, "gmail-confirmation.eml")

    assert Repo.aggregate(Data.Conversations.Conversation, :count) == 0

    check = Data.Inbound.open_confirmation(c.channel.id)
    assert check.code == "482915736"
    assert check.confirm_url =~ "https://mail-settings.google.com/mail/vf-"

    told = told("conversations.forwarding_confirm")

    assert Enum.sort(Enum.map(told, & &1.user_id)) ==
             Enum.sort([c.fiza.id, c.qasim.id, c.tanweer.user_id])

    address = Inbound.address(c.channel.inbound_token)
    assert hd(told).title == "Gmail asks to confirm forwarding for #{address}. Code 482915736."

    {:ok, shown} = Channels.get(scope_for(c.hira), c.channel.id)

    assert %{confirmation: %{code: "482915736", url: "https://mail-settings.google.com/" <> _}} =
             shown.forwarding

    # The same check again tells nobody twice.
    assert {:ok, %{outcome: :gmail_confirmation}} =
             deliver(c, "gmail-confirmation.eml", "Gmail <#{address}>")

    assert length(told("conversations.forwarding_confirm")) == 3

    assert {:ok, %{outcome: :landed}} = deliver(c, "thread-1.eml")
    assert Data.Inbound.open_confirmation(c.channel.id) == nil
    {:ok, shown} = Channels.get(scope_for(c.hira), c.channel.id)
    assert shown.forwarding.confirmation == nil
  end

  test "triage is told with the receiving profile: the team's leads and the profile's owners",
       c do
    assert {:ok, %{outcome: :landed}} = deliver(c, "stranger-corvid.eml")
    told = told("conversations.triage_new") |> Enum.map(& &1.user_id) |> Enum.sort()
    assert told == Enum.sort([c.hira.id, c.bilal.id, c.fiza.id, c.qasim.id])
  end

  test "the log is kept 30 days", c do
    assert {:ok, _} = deliver(c, "thread-1.eml")
    assert Inbound.sweep(Scope.system(), DateTime.add(@now, 29, :day)) == 0
    assert Inbound.sweep(Scope.system(), DateTime.add(@now, 31, :day)) == 1
    assert Inbound.sweep(Scope.system(), DateTime.add(@now, 31, :day)) == 0
  end

  test "the webhook's pair: right, wrong, and off without a password" do
    assert Inbound.authorise("postmark", "inbound-test") == :ok
    assert Inbound.authorise("postmark", "wrong") == {:error, :inbound_unauthorised}
    assert Inbound.authorise(nil, nil) == {:error, :inbound_unauthorised}
    assert Inbound.max_bytes() == 30 * 1024 * 1024
  end
end
