defmodule Core.ConversationsTest do
  @moduledoc """
  AQ-06 §11.6's conversation as read: one team's, through its leads; the
  customer's cut (no note, no address); a contact's conversations across
  platforms.
  """

  use Core.CoreCase, async: true

  alias Core.Conversations

  doctest Conversations

  test "a contact's conversations across platforms, those the caller reads", c do
    c = Map.merge(c, board_cast_fixture())
    fiza = scope_for(c.fiza)
    mei = contact_fixture(fiza, name: "Mei Chen")
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)

    for platform <- [:email, :linkedin] do
      conv = conversation_fixture(fiza, lead: lead, platform: platform)
      message_fixture(fiza, conversation: conv, contact: mei)
    end

    assert {:ok, list} = Conversations.for_contact(fiza, mei.id)
    assert Enum.sort(Enum.map(list, & &1.platform)) == [:email, :linkedin]

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    assert {:ok, []} = Conversations.for_contact(scope_for(c.muaz), mei.id)

    assert Conversations.for_contact(customer_scope_for(c.tanweer), mei.id) ==
             {:error, :not_found}
  end
end
