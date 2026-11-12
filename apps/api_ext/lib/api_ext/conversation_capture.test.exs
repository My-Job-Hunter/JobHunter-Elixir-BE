defmodule ApiExt.ConversationCaptureTest do
  @moduledoc """
  `POST /ext/v1/conversations/capture` (AQ-06 §9, §11.6) on a device
  token: 200 with `{conversation_id, lead_id, lead_title, triage, added,
  link_path}`, triage for an unknown sender, nothing added on a retry; a
  console token is 401.
  """

  use ApiExt.ExtCase, async: true

  alias Core.Auth.Guardian

  setup do
    c = board_cast_fixture()
    {_device, tokens} = connected(c.fiza)
    Map.put(c, :token, tokens.access_token)
  end

  defp body_for(c) do
    %{
      request_id: Ecto.UUID.generate(),
      team_id: c.backend.id,
      profile_id: c.golang.id,
      url: "https://www.linkedin.com/messaging/thread/2-OWM5ZmFrZS10aHJlYWQ=/",
      identity: nil,
      fields: %{
        captured_at: "2026-11-11T08:59:00Z",
        page_kind: "thread",
        thread_id: "2-OWM5ZmFrZS10aHJlYWQ=",
        other_profile_url: "https://www.linkedin.com/in/ACoAAAbcdEf/",
        other_name: "Sam Recruiter",
        messages: [
          %{external_id: nil, side: "them", sent_text: "Today 9:15 AM", text: "Hello Tanweer"}
        ]
      }
    }
  end

  test "200, the answer's exact keys, triage; a retry adds nothing; a console token is 401", c do
    first = call(c.token, :post, "/v1/conversations/capture", body_for(c))
    assert first.status == 200
    answer = Jason.decode!(first.resp_body)

    assert answer |> Map.keys() |> Enum.sort() ==
             ~w(added conversation_id lead_id lead_title link_path triage)

    assert answer["triage"] and answer["added"] == 1 and answer["lead_id"] == nil
    assert answer["link_path"] == "/triage?team=#{c.backend.id}"

    again =
      Jason.decode!(call(c.token, :post, "/v1/conversations/capture", body_for(c)).resp_body)

    assert again["added"] == 0 and again["conversation_id"] == answer["conversation_id"]

    {:ok, console} = Guardian.tokens_for(c.fiza)

    assert call(console.access_token, :post, "/v1/conversations/capture", body_for(c)).status ==
             401
  end
end
