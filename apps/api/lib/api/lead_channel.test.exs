defmodule Api.LeadChannelTest do
  @moduledoc """
  `lead:<id>` (AQ-04B §8.3): whoever reads the lead and its customer join;
  everyone else is refused without a reason. It hears `event_added` when
  the ledger grows and `notes_changed` for a note, ids only.
  """

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian
  alias Core.Leads.{FollowUp, Notes}

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

  test "its readers and its customer join; another team, another customer, a stranger do not",
       c do
    topic = "lead:" <> c.lead.id
    tanweer = Data.Accounts.get_user(c.tanweer.user_id)

    for user <- [c.fiza, c.hira, c.dawud, tanweer],
        do:
          assert(
            {:ok, _reply, _socket} = subscribe_and_join(socket_for(user), Api.LeadChannel, topic)
          )

    farah = member_fixture(c.frontend, :member, user_fixture())

    for user <- [farah, Data.Accounts.get_user(c.naveed.user_id), user_fixture()],
        do:
          assert(
            {:error, %{reason: "unauthorized"}} =
              subscribe_and_join(socket_for(user), Api.LeadChannel, topic)
          )

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(c.muaz), Api.LeadChannel, topic)
  end

  test "hears event_added and notes_changed, by id", c do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(c.hira), Api.LeadChannel, "lead:" <> c.lead.id)

    {:ok, _note} = Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "Hello"}, @now)
    id = c.lead.id
    assert_push "notes_changed", %{lead: ^id}
    assert_push "event_added", %{lead: ^id}

    {:ok, _sheet} =
      FollowUp.log(
        scope_for(c.fiza),
        id,
        %{"from" => %{"state" => "in_progress", "stage" => "applied"}},
        @now
      )

    assert_push "event_added", %{lead: ^id}
  end

  test "is read-only", c do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(c.fiza), Api.LeadChannel, "lead:" <> c.lead.id)

    ref = push(socket, "anything", %{})
    # A second, not ExUnit's 100 ms: on a loaded machine the reply took longer (AQ-05's run).
    assert_reply ref, :error, %{reason: "read_only"}, 1_000
  end
end
