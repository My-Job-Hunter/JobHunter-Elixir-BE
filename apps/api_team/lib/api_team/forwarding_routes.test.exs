defmodule ApiTeam.ForwardingRoutesTest do
  @moduledoc """
  AQ-09 §11.2 and §11.4 over HTTP, in the console: an email channel's
  `forwarding` (and `null` on any other kind; `inbound_address` gone),
  *New address* (200 the channel, 422 on another kind, 403 with §4's
  words), and a proposed meeting's *Confirm* (200 the meeting) and
  *Dismiss* (204), 409 `meeting_not_proposed` otherwise.
  """

  use ApiTeam.TeamCase, async: true

  setup do
    c = board_cast_fixture()
    email = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    linkedin = channel_fixture(c.tanweer)
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.merge(c, %{email: email, linkedin: linkedin, lead: lead})
  end

  defp proposed(c) do
    starts = DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)

    {:ok, m} =
      Data.Meetings.create(%{
        organisation_id: c.lead.organisation_id,
        lead_id: c.lead.id,
        title: "Technical interview",
        meeting_kind: :technical,
        platform: :google_meet,
        starts_at: starts,
        ends_at: DateTime.add(starts, 3600, :second),
        time_zone: "Asia/Karachi",
        status: :proposed,
        source: :email_invite,
        proposal: %{
          "organizer" => "Omar Haddad",
          "method" => "REQUEST",
          "uid" => "u@corvid.example",
          "sequence" => 0,
          "change" => nil
        }
      })

    m
  end

  test "GET /channels/:id: forwarding on an email channel, null otherwise; no inbound_address",
       c do
    channel = body(call(c.hira, :get, "/v1/channels/#{c.email.id}"))
    refute Map.has_key?(channel, "inbound_address")

    assert %{
             "address" => address,
             "last_inbound_at" => nil,
             "confirmation" => nil,
             "can_renew" => true
           } = channel["forwarding"]

    assert address == "in+#{c.email.inbound_token}@inbound.autoqare.local"

    listed = body(call(c.hira, :get, "/v1/customers/#{c.tanweer.id}/channels"))
    assert Enum.all?(listed, &Map.has_key?(&1, "forwarding"))
    assert Enum.find(listed, &(&1["id"] == c.linkedin.id))["forwarding"] == nil
  end

  test "POST /channels/:id/inbound-address: 200 a new address; 422 on LinkedIn; 403 for staff who own none of its profiles",
       c do
    renewed = call(c.hira, :post, "/v1/channels/#{c.email.id}/inbound-address", %{})
    assert renewed.status == 200
    refute body(renewed)["forwarding"]["address"] =~ c.email.inbound_token

    refused = call(c.hira, :post, "/v1/channels/#{c.linkedin.id}/inbound-address", %{})
    assert refused.status == 422 and code(refused) == "validation_failed"

    assert body(refused)["error"]["details"] == %{
             "kind" => ["Only an email channel has a forwarding address."]
           }

    forbidden = call(c.muaz, :post, "/v1/channels/#{c.email.id}/inbound-address", %{})
    assert forbidden.status == 403

    assert body(forbidden)["error"]["message"] ==
             "Only the customer's leads and owners can change it."
  end

  test "POST /meetings/:id/confirm 200 the meeting; again 409; dismiss 204 removes a proposed one",
       c do
    m = proposed(c)
    shown = body(call(c.fiza, :get, "/v1/meetings/#{m.id}"))
    assert shown["status"] == "proposed" and shown["can"]["edit"] == true

    assert shown["proposal"] == %{
             "organizer" => "Omar Haddad",
             "method" => "REQUEST",
             "sequence" => 0,
             "change" => nil
           }

    assert shown["from_message"] == nil and shown["source"] == "email_invite"

    confirmed = call(c.fiza, :post, "/v1/meetings/#{m.id}/confirm", %{})
    assert confirmed.status == 200 and body(confirmed)["status"] == "scheduled"

    again = call(c.fiza, :post, "/v1/meetings/#{m.id}/confirm", %{})
    assert again.status == 409 and code(again) == "meeting_not_proposed"
    assert body(again)["error"]["details"] == %{"status" => "scheduled"}
    assert call(c.fiza, :post, "/v1/meetings/#{m.id}/dismiss", %{}).status == 409

    other = proposed(c)
    gone = call(c.fiza, :post, "/v1/meetings/#{other.id}/dismiss", %{})
    assert gone.status == 204 and gone.resp_body == ""
    assert call(c.fiza, :get, "/v1/meetings/#{other.id}").status == 404
  end
end
