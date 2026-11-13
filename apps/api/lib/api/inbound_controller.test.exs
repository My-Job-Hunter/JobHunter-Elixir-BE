defmodule Api.InboundControllerTest do
  @moduledoc """
  `POST /inbound/email` (AQ-09 §6.2, §11.4) through the endpoint: basic
  auth (401 with no body), the 30 MB cap on this route alone (413, logged
  `too_large` when the pair is right), Postmark's documented JSON landing
  once (its retry adds nothing), an unknown address answered 200 and
  logged, 503 `inbound_off` without a password, 429 per address; and the
  dev route's action, `{outcome, message_id, conversation_id}`.
  """

  use Api.ConnCase, async: false

  alias Data.Inbound.InboundMessage
  alias Data.Repo

  @fixture Path.expand("../../../core/priv/eml/postmark-inbound.json", __DIR__)

  setup do
    c = board_cast_fixture()
    channel = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    Map.merge(c, %{channel: channel})
  end

  defp body(c),
    do: @fixture |> File.read!() |> String.replace("abcdefghjk", c.channel.inbound_token)

  defp post_inbound(conn, body, auth \\ {"postmark", "inbound-test"}) do
    conn =
      case auth do
        {user, password} ->
          put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(user, password))

        nil ->
          conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/inbound/email", body)
  end

  test "Postmark's JSON lands once: 200 landed, then its retry 200 duplicate and no new row", c do
    conn = post_inbound(build_conn(), body(c))
    assert json_response(conn, 200) == %{"outcome" => "landed"}

    conn = post_inbound(build_conn(), body(c))
    assert json_response(conn, 200) == %{"outcome" => "duplicate"}

    assert [
             %{
               provider: :postmark,
               provider_message_id: "73e6d360-66eb-11e1-8e72-a8904824019b",
               outcome: :landed
             }
           ] =
             Repo.all(InboundMessage)

    assert Repo.aggregate(Data.Conversations.Message, :count) == 1
  end

  test "a wrong pair, or none, is 401 with no body; nothing logged", c do
    conn = post_inbound(build_conn(), body(c), {"postmark", "wrong"})
    assert conn.status == 401 and conn.resp_body == ""
    assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="inbound")]

    assert post_inbound(build_conn(), body(c), nil).status == 401
    assert Repo.all(InboundMessage) == []
  end

  test "an unknown address answers 200 and is logged", c do
    body = String.replace(body(c), c.channel.inbound_token, "zzzzzzzzzz")

    assert json_response(post_inbound(build_conn(), body), 200) == %{
             "outcome" => "unknown_address"
           }

    assert [%{outcome: :unknown_address, organisation_id: nil}] = Repo.all(InboundMessage)
  end

  test "over 30 MB on this route is 413 and logged too_large; the same size elsewhere isn't this cap",
       c do
    huge = ~s({"RawEmail":") <> String.duplicate("a", 30 * 1024 * 1024) <> ~s("})

    conn = post_inbound(build_conn(), huge)
    assert %{"error" => %{"code" => "file_too_large"}} = json_response(conn, 413)
    assert [%{outcome: :too_large, bytes: bytes}] = Repo.all(InboundMessage)
    assert bytes > 30 * 1024 * 1024

    # With a wrong pair: refused, not logged.
    assert post_inbound(build_conn(), huge, {"postmark", "wrong"}).status == 401
    assert length(Repo.all(InboundMessage)) == 1

    # Under the cap but over Plug's 8 MB: this route reads it.
    big =
      String.replace(
        body(c),
        ~s("HtmlBody": ""),
        ~s("HtmlBody": ") <> String.duplicate("b", 9_000_000) <> ~s(")
      )

    assert json_response(post_inbound(build_conn(), big), 200) == %{"outcome" => "landed"}

    # Any other route keeps Plug's own cap.
    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/team/v1/auth/login", big)
    end
  end

  test "without a password the webhook is off: 503 inbound_off", c do
    held = Application.get_env(:core, :inbound)
    Application.put_env(:core, :inbound, Keyword.put(held, :password, nil))
    on_exit(fn -> Application.put_env(:core, :inbound, held) end)

    assert %{"error" => %{"code" => "inbound_off"}} =
             json_response(post_inbound(build_conn(), body(c)), 503)
  end

  test "one address flooding is 429", c do
    held = Application.get_env(:core, :inbound)
    limit = Application.get_env(:core, Core.Plugs.RateLimit)
    Application.put_env(:core, :inbound, Keyword.put(held, :per_minute, 1))
    Application.put_env(:core, Core.Plugs.RateLimit, enabled: true)

    on_exit(fn ->
      Application.put_env(:core, :inbound, held)
      Application.put_env(:core, Core.Plugs.RateLimit, limit)
    end)

    assert json_response(post_inbound(build_conn(), body(c)), 200)
    other = String.replace(body(c), "73e6d360", "83e6d360")

    assert %{"error" => %{"code" => "rate_limited"}} =
             json_response(post_inbound(build_conn(), other), 429)
  end

  test "the dev route's action: {to, eml} through the same intake", c do
    eml = File.read!(Path.expand("../../../core/priv/eml/thread-1.eml", __DIR__))
    to = Core.Inbound.address(c.channel.inbound_token)

    conn = Api.InboundController.dev(build_conn(), %{"to" => to, "eml" => eml})

    assert %{"outcome" => "landed", "message_id" => id, "conversation_id" => cid} =
             json_response(conn, 200)

    assert is_binary(id) and is_binary(cid)

    conn =
      Api.InboundController.dev(build_conn(), %{"to" => "nobody@elsewhere.example", "eml" => eml})

    assert json_response(conn, 200) == %{
             "outcome" => "unknown_address",
             "message_id" => nil,
             "conversation_id" => nil
           }

    assert [%{provider: :dev, outcome: :landed}, %{provider: :dev, outcome: :unknown_address}] =
             InboundMessage |> Repo.all() |> Enum.sort_by(& &1.received_at)
  end
end
