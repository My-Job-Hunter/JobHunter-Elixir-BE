defmodule Core.Conversations.Notices do
  @moduledoc """
  Who is told about a conversation (AQ-06 §11.6), inside the write's
  transaction, each row ensured by its dedupe key and worded for the
  recipient; nobody is told of their own act. The seam plans each row's
  deliveries (AQ-08 §7.1).

  | Kind | Who | Dedupe |
  |---|---|---|
  | `conversations.reply_received` | the lead's owner; **the customer when the lead's team has `customer_sees_conversations` on** (AQ-08 QP8-5) | `message:<id>` |
  | `conversations.triage_new` | the team's leads and the profile's owners, when known | `conversation:<id>:triage` |

  Each answers the socket events its new rows make (`notification_created`).
  """

  alias Core.Conversations
  alias Core.Leads.Words
  alias Core.Notifications
  alias Core.Realtime
  alias Data.Scope
  alias Data.Teams

  @doc """
  `conversations.reply_received` to the lead's owner: "Mei Chen replied on
  “Backend Developer · Bamboo Invest”". **And to the customer** (AQ-08
  QP8-5) when the lead's team has `customer_sees_conversations` on and the
  customer has a portal account: the same words, opening the application
  in the portal, with no staff actor.
  """
  @spec reply_received(Scope.t(), map(), map(), String.t()) :: list()
  def reply_received(scope, lead, message, who) do
    attrs = %{
      organisation_id: lead.organisation_id,
      lead_id: lead.id,
      title: "#{who} replied on #{Words.job(lead.job)}",
      body: excerpt(message.body_text),
      link_path: "/leads/#{lead.id}",
      dedupe_key: "message:#{message.id}"
    }

    [
      tell(scope, lead.owner_user_id, "conversations.reply_received", attrs),
      tell_customer(scope, lead, attrs)
    ]
  end

  defp tell_customer(scope, lead, attrs) do
    customer_user_id = lead.profile.customer.user_id

    if customer_user_id && Teams.get_settings(lead.job.team_id).customer_sees_conversations do
      tell(
        scope,
        customer_user_id,
        "conversations.reply_received",
        %{attrs | link_path: "/applications/#{lead.id}"},
        nil
      )
    else
      []
    end
  end

  @doc """
  `conversations.triage_new` to the team's leads and the acting profile's
  owners (`profile`, when known; a list of them for a forwarded mail's
  receiving channel, AQ-09 QP9-15): "New in Triage: Mei Chen · Platform
  Engineer role".
  """
  @spec triage_new(Scope.t(), map(), String.t(), map() | [map()] | nil) :: list()
  def triage_new(scope, conversation, who, profiles) do
    leads = for m <- Teams.list_members(conversation.team_id), m.role == :lead, do: m.user_id
    owners = profiles |> List.wrap() |> Enum.flat_map(&profile_owners/1)
    about = if conversation.subject, do: " · " <> conversation.subject, else: ""

    for user_id <- Enum.uniq(leads ++ owners) do
      tell(scope, user_id, "conversations.triage_new", %{
        organisation_id: conversation.organisation_id,
        title: "New in Triage: #{who}#{about}",
        link_path: "/triage?team=#{conversation.team_id}",
        dedupe_key: "conversation:#{conversation.id}:triage"
      })
    end
  end

  defp profile_owners(profile) do
    case Map.get(profile, :profile_members) do
      members when is_list(members) -> Enum.map(members, & &1.user_id)
      _not_loaded -> []
    end
  end

  @doc "Someone's name as the notices say it, for a message's other side."
  @spec who(map()) :: String.t()
  def who(%{from_kind: :contact, from_contact: %{name: name}}), do: name
  def who(%{from_text: text}) when is_binary(text), do: Conversations.names_only(text) || text
  def who(_message), do: "Someone"

  defp excerpt(nil), do: nil

  defp excerpt(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > 140, do: String.slice(text, 0, 139) <> "…", else: text
  end

  defp tell(scope, user_id, kind, attrs, actor_user_id \\ :scope) do
    if is_nil(user_id) or user_id == Scope.user_id(scope) do
      []
    else
      actor_user_id = if actor_user_id == :scope, do: Scope.user_id(scope), else: actor_user_id

      {:ok, row} =
        Notifications.ensure(
          scope,
          Map.merge(attrs, %{
            user_id: user_id,
            notification_kind_key: kind,
            actor_user_id: actor_user_id
          })
        )

      if row.is_new,
        do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
        else: []
    end
  end
end
