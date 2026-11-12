defmodule ApiClient.MeetingControllerTest do
  @moduledoc """
  The portal's half of AQ-06 (§11.2, §12.2): the customer's meetings and
  *Add to calendar*; a lead's conversation tabs when the team allows them,
  with no staff note, no address and nothing to do; another customer's
  meeting is 404.
  """

  use ApiClient.ClientCase, async: true

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    lead = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    meeting = meeting_fixture(fiza, lead: lead, attendees: [{:user, c.fiza}, :customer])
    conv = conversation_fixture(fiza, lead: lead, platform: :linkedin)
    omar = contact_fixture(fiza, name: "Omar Haddad")

    _in =
      message_fixture(fiza,
        conversation: conv,
        contact: omar,
        from_text: "Omar Haddad <omar.haddad@corvid.example>",
        body_text: "Are you free Tuesday?"
      )

    _note = message_fixture(fiza, conversation: conv, is_internal: true, body_text: "Staff only")
    Map.merge(c, %{lead: lead, meeting: meeting})
  end

  test "GET /meetings: their own, cut; the ICS; another customer's is 404", c do
    page = body(as_customer(c.tanweer, :get, "/v1/meetings"))
    assert [%{"id" => id, "notes_md" => nil, "clash" => nil, "can" => can}] = page["items"]
    assert id == c.meeting.id
    assert Enum.all?(Map.values(can), &(&1 == false))

    ics = as_customer(c.tanweer, :get, "/v1/meetings/#{id}/ics")
    assert ics.status == 200 and ics.resp_body =~ "BEGIN:VEVENT"
    assert ["text/calendar; charset=utf-8"] = get_resp_header(ics, "content-type")

    assert body(as_customer(c.naveed, :get, "/v1/meetings"))["items"] == []
    assert as_customer(c.naveed, :get, "/v1/meetings/#{id}/ics").status == 404
  end

  test "GET /leads/:id gains conversations: no note, no address, can all false; none when the team says so",
       c do
    sheet = body(as_customer(c.tanweer, :get, "/v1/leads/#{c.lead.id}"))
    assert [%{"platform" => "linkedin", "messages" => [message]}] = sheet["conversations"]
    assert message["body_text"] == "Are you free Tuesday?"

    assert message["can"] == %{
             "edit" => false,
             "delete" => false,
             "classify" => false,
             "reply" => false
           }

    refute inspect(sheet["conversations"]) =~ "corvid.example"
    # The customer never sees a team's name (QP4a-14).
    assert Enum.all?(sheet["conversations"], &is_nil(&1["team"]))

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    assert body(as_customer(c.tanweer, :get, "/v1/leads/#{c.lead.id}"))["conversations"] == nil
  end
end
