defmodule ApiClient.ForwardingRoutesTest do
  @moduledoc """
  AQ-09 §12.2 and §11.4 in the portal: the customer sees their email
  channel's `forwarding` and makes a new address (200 the channel; 422 on
  another kind); another customer's channel is 404; a proposed meeting is
  never listed nor shown, and every meeting carries `from_message` and
  `proposal` as `null`.
  """

  use ApiClient.ClientCase, async: true

  setup do
    c = board_cast_fixture()
    email = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    linkedin = channel_fixture(c.tanweer)
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.merge(c, %{email: email, linkedin: linkedin, lead: lead})
  end

  test "GET /channels and POST /channels/:id/inbound-address", c do
    channels = body(as_customer(c.tanweer, :get, "/v1/channels"))
    mine = Enum.find(channels, &(&1["id"] == c.email.id))
    assert mine["forwarding"]["can_renew"] == true
    assert mine["forwarding"]["address"] =~ c.email.inbound_token
    assert Enum.find(channels, &(&1["id"] == c.linkedin.id))["forwarding"] == nil
    refute Map.has_key?(mine, "inbound_address")

    renewed = as_customer(c.tanweer, :post, "/v1/channels/#{c.email.id}/inbound-address", %{})
    assert renewed.status == 200
    refute body(renewed)["forwarding"]["address"] =~ c.email.inbound_token

    assert as_customer(c.tanweer, :post, "/v1/channels/#{c.linkedin.id}/inbound-address", %{}).status ==
             422

    assert as_customer(c.naveed, :post, "/v1/channels/#{c.email.id}/inbound-address", %{}).status ==
             404
  end

  test "a proposed meeting is never the customer's to see; the others carry the new members as null",
       c do
    starts = DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
    scheduled = meeting_fixture(scope_for(c.fiza), lead: c.lead, starts_at: starts)

    {:ok, proposed} =
      Data.Meetings.create(%{
        organisation_id: c.lead.organisation_id,
        lead_id: c.lead.id,
        title: "Final round",
        meeting_kind: :final,
        platform: :zoom,
        starts_at: DateTime.add(starts, 86_400, :second),
        ends_at: DateTime.add(starts, 90_000, :second),
        time_zone: "Asia/Karachi",
        status: :proposed,
        source: :email_invite,
        proposal: %{"uid" => "u@corvid.example", "sequence" => 0, "method" => "REQUEST"}
      })

    assert [%{"id" => id} = shown] = body(as_customer(c.tanweer, :get, "/v1/meetings"))["items"]
    assert id == scheduled.id

    assert shown["from_message"] == nil and shown["proposal"] == nil and
             shown["source"] == "manual"

    assert as_customer(c.tanweer, :get, "/v1/meetings/#{proposed.id}/ics").status == 404
  end
end
