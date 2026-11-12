defmodule Api.ConnCase do
  @moduledoc """
  Test case for anything that goes through the endpoint (copied from
  mCart).

  `authed_conn/2` builds a real signed request rather than stubbing the
  assigns — an auth test that skips the pipeline proves nothing about the
  pipeline. Nothing calls it in P0: issuing a token writes to
  `guardian_tokens`, which arrives in P1 with the users it belongs to.
  """

  use ExUnit.CaseTemplate

  alias Core.Auth.Guardian
  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.ConnTest
  alias Plug.Conn

  using do
    quote do
      @endpoint Api.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Api.ConnCase
      import Data.Fixtures
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: ConnTest.build_conn()}
  end

  @doc "A conn carrying a genuine bearer token for `user`."
  def authed_conn(conn, user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    Conn.put_req_header(conn, "authorization", "Bearer " <> tokens.access_token)
  end
end
