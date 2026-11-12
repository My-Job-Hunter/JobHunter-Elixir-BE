defmodule Api.ConversationChannelsTest do
  @moduledoc """
  AQ-06 §11.4, §11.6 over real channels, after commit and ids only:
  `message_added {lead, conversation}` on `lead:`; `meeting_changed {lead,
  meeting}` on `lead:` and `customer:`; `triage_changed {team}` on `team:`.
  """

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian
  alias Core.Conversations.{Messages, Triage}
  alias Core.Meetings

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.put(c, :lead, lead)
  end

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  test "lead: hears message_added and meeting_changed; customer: meeting_changed", c do
    id = c.lead.id
    {:ok, _, _} = subscribe_and_join(socket_for(c.hira), Api.LeadChannel, "lead:" <> id)

    tanweer = Data.Accounts.get_user(c.tanweer.user_id)

    {:ok, _, _} =
      subscribe_and_join(socket_for(tanweer), Api.CustomerChannel, "customer:" <> c.tanweer.id)

    {:ok, conv} =
      Messages.create(
        scope_for(c.fiza),
        %{
          "lead_id" => id,
          "direction" => "out",
          "from" => %{"kind" => "user"},
          "sent_at" => "2026-11-10T09:00:00Z",
          "body_md" => "Hello"
        },
        @now
      )

    conv_id = conv.id
    assert_push "message_added", %{lead: ^id, conversation: ^conv_id}

    {:ok, m} =
      Meetings.schedule(
        scope_for(c.fiza),
        id,
        %{
          "title" => "Technical interview",
          "meeting_kind" => "technical",
          "platform" => "zoom",
          "starts_at" => "2026-11-18T09:00:00Z",
          "ends_at" => "2026-11-18T10:00:00Z",
          "time_zone" => "Europe/Berlin"
        },
        @now
      )

    meeting_id = m.id
    assert_push "meeting_changed", %{lead: ^id, meeting: ^meeting_id}
    assert_push "meeting_changed", %{lead: ^id, meeting: ^meeting_id}
  end

  test "team: hears triage_changed when a conversation lands in triage and when it leaves", c do
    team_id = c.backend.id
    {:ok, _, _} = subscribe_and_join(socket_for(c.muaz), Api.TeamChannel, "team:" <> team_id)

    {:ok, conv} =
      Messages.create(
        scope_for(c.fiza),
        %{
          "team_id" => team_id,
          "direction" => "in",
          "from" => %{"kind" => "text", "text" => "Sam <sam@example.com>"},
          "sent_at" => "2026-11-10T09:00:00Z",
          "body_md" => "Hello"
        },
        @now
      )

    assert_push "triage_changed", %{team: ^team_id}

    {:ok, _} = Triage.ignore(scope_for(c.fiza), conv.id, @now)
    assert_push "triage_changed", %{team: ^team_id}
  end
end
