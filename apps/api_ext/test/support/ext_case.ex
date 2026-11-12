defmodule ApiExt.ExtCase do
  @moduledoc """
  For the extension's controllers: `ApiExt.Router` driven with `Plug.Test`
  over the SQL sandbox, with a genuine **device** token on the request — a
  Guardian pair whose `sid` is a live device and whose `dev.app` is `ext`,
  as `POST /ext/v1/session` mints it.
  """

  use ExUnit.CaseTemplate

  alias Core.Auth.Guardian
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import ApiExt.ExtCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "A live device of `user` and its token pair: `{device, tokens}`."
  def connected(user) do
    device = Data.Fixtures.device_fixture(Data.Fixtures.scope_for(user))

    {:ok, tokens} =
      Guardian.tokens_for(user, %{
        "sid" => device.id,
        "dev" => %{"app" => "ext", "agent" => "test"}
      })

    {device, tokens}
  end

  @doc "Sends `method` `path` with `params` through the extension's router, with `token` (or none)."
  def call(token, method, path, params \\ %{}, headers \\ []) do
    conn =
      method
      |> Plug.Test.conn(path, params)
      |> Plug.Conn.put_req_header("accept", "application/json")

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    |> ApiExt.Router.call(ApiExt.Router.init([]))
  end

  @doc "The decoded JSON body."
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc "The error code of a refused answer."
  def code(conn), do: body(conn)["error"]["code"]
end
