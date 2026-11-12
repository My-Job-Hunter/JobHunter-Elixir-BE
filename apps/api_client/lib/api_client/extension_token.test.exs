defmodule ApiClient.ExtensionTokenTest do
  @moduledoc "AQ-05 §7: an extension's token never works on `/client`, its refresh neither."

  use ApiClient.ClientCase, async: true

  alias Core.Auth.Guardian

  test "a token whose app is ext is 401 here" do
    org = organisation_fixture()
    tanweer = customer_fixture(org, [team_fixture(org)], login: true)
    user = Data.Accounts.get_user(tanweer.user_id)

    {:ok, tokens} =
      Guardian.tokens_for(user, %{"sid" => Ecto.UUID.generate(), "dev" => %{"app" => "ext"}})

    conn =
      :get
      |> Plug.Test.conn("/v1/customer")
      |> put_req_header("authorization", "Bearer " <> tokens.access_token)
      |> ApiClient.Router.call(ApiClient.Router.init([]))

    assert conn.status == 401
    assert body(conn)["error"]["code"] == "unauthenticated"

    conn =
      :post
      |> Plug.Test.conn("/v1/auth/refresh", %{"refresh_token" => tokens.refresh_token})
      |> ApiClient.Router.call(ApiClient.Router.init([]))

    assert conn.status == 401

    # The portal's own token still works.
    assert call(user, :get, "/v1/customer").status == 200
  end
end
