defmodule Api.ChannelCase do
  @moduledoc """
  Test case for anything that goes through the socket or a **joined channel**
  (copied from AutoCare).

  `Api.ConnCase` covers the HTTP half. `Phoenix.ChannelTest` starts a real
  channel process, so `assert_push` proves a message reached a subscriber the
  way the app delivers it — rather than proving a `%Broadcast{}` reached a
  bare process that subscribed to PubSub by hand, which is the test that
  stayed green while AutoCare's broadcasts crashed every joined client.

  It lives in `api` because `@endpoint` has to be `Api.Endpoint`, and `core`
  may never name it. In P0 its one use is proving the socket refuses.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint Api.Endpoint

      import Phoenix.ChannelTest
      # `Phoenix.ConnTest.connect/2` is the HTTP `CONNECT` verb, which no
      # channel test sends, and it collides with `ChannelTest.connect/2` —
      # the one that opens the socket.
      import Phoenix.ConnTest, except: [connect: 2]
      import Api.ConnCase, only: [authed_conn: 2]
      import Data.Fixtures
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
