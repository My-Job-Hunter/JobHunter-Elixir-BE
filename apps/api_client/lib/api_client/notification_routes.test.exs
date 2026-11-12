defmodule ApiClient.NotificationRoutesTest do
  @moduledoc """
  P8's portal routes (AQ-08 §11.1, §11.4, §12.2): the same settings without
  the extension column, 422 on `extension` for a customer, and push on this
  browser recorded as the portal's (`client`), whatever the body says.
  """

  use ApiClient.ClientCase, async: true

  setup do
    board_cast_fixture()
  end

  test "GET /notifications/settings: no extension anywhere; PUT on extension is 422", c do
    conn = as_customer(c.tanweer, :get, "/v1/notifications/settings")
    assert conn.status == 200
    settings = body(conn)

    refute Enum.any?(settings["groups"], &("extension" in &1["uses"]))
    assert settings["has"] == %{"push" => false, "extension" => false}
    assert List.last(settings["groups"])["key"] == "account"

    refused =
      as_customer(c.tanweer, :put, "/v1/notifications/settings/groups/conversations", %{
        extension: false
      })

    assert refused.status == 422

    assert body(refused)["error"]["details"] == %{
             "extension" => ["The extension is for the team."]
           }

    ok = as_customer(c.tanweer, :put, "/v1/notifications/settings/groups/leads", %{push: false})
    assert ok.status == 200
    assert %{"push" => false} = Enum.find(body(ok)["groups"], &(&1["key"] == "leads"))
  end

  test "POST /me/push: the portal's browser is `client`; has.push follows it", c do
    created =
      as_customer(c.tanweer, :post, "/v1/me/push", %{
        endpoint: "https://web.push.apple.com/abc",
        keys: %{p256dh: "BPkey", auth: "authsecret"},
        app: "team",
        user_agent: "Safari on iPhone"
      })

    assert created.status == 201

    assert [%{"app" => "client", "user_agent" => "Safari on iPhone"}] = body(created)["devices"]

    assert %{"push" => true} =
             body(as_customer(c.tanweer, :get, "/v1/notifications/settings"))["has"]
  end
end
