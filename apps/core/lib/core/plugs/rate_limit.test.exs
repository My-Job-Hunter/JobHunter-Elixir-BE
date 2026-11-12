defmodule Core.Plugs.RateLimitTest do
  @moduledoc """
  Rate limiting is disabled for the rest of the suite, because a suite that
  hammers an endpoint is the point of the suite.

  **That makes this file the only thing standing between a configured limit
  and a limit nobody has ever seen work.** So it turns the switch on and
  asserts it bites, per caller, and that the window is real.

  `async: false` — it swaps global config and shares one ETS table.
  """

  use ExUnit.Case, async: false

  alias Core.Plugs.RateLimit

  setup do
    original = Application.get_env(:core, RateLimit)
    Application.put_env(:core, RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:core, RateLimit, original || [enabled: false]) end)

    # A fresh key per test, so one test's spending is not another's.
    %{key: "test:#{System.unique_integer([:positive])}"}
  end

  describe "check" do
    test "allows up to the limit", %{key: key} do
      assert RateLimit.check(key, 60_000, 3) == :allow
      assert RateLimit.check(key, 60_000, 3) == :allow
      assert RateLimit.check(key, 60_000, 3) == :allow
    end

    test "denies the one after", %{key: key} do
      for _allowed <- 1..3, do: RateLimit.check(key, 60_000, 3)

      assert {:deny, retry_after_ms} = RateLimit.check(key, 60_000, 3)
      assert retry_after_ms > 0
    end

    # A team behind one office address is several real people, and one
    # member's posting must not throttle the rest.
    test "one caller's spending does not count against another", %{key: key} do
      for _allowed <- 1..3, do: RateLimit.check(key, 60_000, 3)

      assert {:deny, _ms} = RateLimit.check(key, 60_000, 3)
      assert RateLimit.check("#{key}:other", 60_000, 3) == :allow
    end

    test "a short window lets the caller back in", %{key: key} do
      assert RateLimit.check(key, 50, 1) == :allow
      assert {:deny, _ms} = RateLimit.check(key, 50, 1)

      Process.sleep(80)

      assert RateLimit.check(key, 50, 1) == :allow
    end

    test "allows everything when switched off", %{key: key} do
      Application.put_env(:core, RateLimit, enabled: false)

      for _unlimited <- 1..20 do
        assert RateLimit.check(key, 60_000, 1) == :allow
      end
    end
  end

  describe "as a plug" do
    defp conn_for(caller) do
      :get
      |> Plug.Test.conn("/team/v1/leads/l1/notes")
      |> Plug.Conn.assign(:current_user, caller)
    end

    test "passes a request under the limit" do
      user = %{id: Ecto.UUID.generate()}
      opts = RateLimit.init(name: "plugtest#{System.unique_integer([:positive])}", limit: 2)

      refute RateLimit.call(conn_for(user), opts).halted
    end

    test "halts with 429 and a Retry-After header over the limit" do
      user = %{id: Ecto.UUID.generate()}
      opts = RateLimit.init(name: "plugtest#{System.unique_integer([:positive])}", limit: 1)

      RateLimit.call(conn_for(user), opts)
      conn = RateLimit.call(conn_for(user), opts)

      assert conn.halted
      assert conn.status == 429
      assert [retry_after] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    # Our contract is `{error: {code, message, details}}` and nothing else —
    # a plug that halts before the fallback controller has to honour it too.
    test "the refusal uses the house error shape" do
      user = %{id: Ecto.UUID.generate()}
      opts = RateLimit.init(name: "plugtest#{System.unique_integer([:positive])}", limit: 1)

      RateLimit.call(conn_for(user), opts)
      conn = RateLimit.call(conn_for(user), opts)

      assert %{"error" => %{"code" => "rate_limited", "message" => message, "details" => details}} =
               Jason.decode!(conn.resp_body)

      assert message =~ "slow down" or message =~ "Wait a moment"
      assert details["retry_after_seconds"] > 0
    end

    test "signed-in callers get their own budget" do
      name = "plugtest#{System.unique_integer([:positive])}"
      opts = RateLimit.init(name: name, limit: 1)

      RateLimit.call(conn_for(%{id: Ecto.UUID.generate()}), opts)

      refute RateLimit.call(conn_for(%{id: Ecto.UUID.generate()}), opts).halted
    end

    # AQ-05 §11.4: 120 a minute per device, so one person's two browsers
    # have a budget each.
    test "by: :device keys on the connected extension, not the person" do
      name = "plugtest#{System.unique_integer([:positive])}"
      opts = RateLimit.init(name: name, limit: 1, by: :device)
      user = %{id: Ecto.UUID.generate()}
      on = fn device -> user |> conn_for() |> Plug.Conn.assign(:device, %{id: device}) end

      first = Ecto.UUID.generate()
      RateLimit.call(on.(first), opts)

      assert RateLimit.call(on.(first), opts).halted
      refute RateLimit.call(on.(Ecto.UUID.generate()), opts).halted
    end

    # Behind a load balancer `remote_ip` is the proxy, and keying on it
    # collapses every caller into one bucket.
    test "an anonymous caller is keyed by the forwarded address" do
      name = "plugtest#{System.unique_integer([:positive])}"
      opts = RateLimit.init(name: name, limit: 1)

      first =
        :get
        |> Plug.Test.conn("/team/v1/leads/l1/notes")
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.5, 10.0.0.1")

      second =
        :get
        |> Plug.Test.conn("/team/v1/leads/l1/notes")
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9")

      RateLimit.call(first, opts)

      assert RateLimit.client_ip(first) == "203.0.113.5"
      refute RateLimit.call(second, opts).halted
    end
  end
end
