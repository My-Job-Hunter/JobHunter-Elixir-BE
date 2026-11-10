defmodule ApiTeam.TeamCase do
  @moduledoc """
  For the console's controllers: `ApiTeam.Router` driven with `Plug.Test`
  over the SQL sandbox, with a genuine bearer token on the request.
  """

  use ExUnit.CaseTemplate

  alias Core.Auth.Guardian
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import ApiTeam.TeamCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Sends `method` `path` with JSON `params` as `user` through the team router."
  def call(user, method, path, params \\ %{}) do
    {:ok, tokens} = Guardian.tokens_for(user)

    method
    |> Plug.Test.conn(path, params)
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tokens.access_token)
    |> ApiTeam.Router.call(ApiTeam.Router.init([]))
  end

  @doc "The decoded JSON body."
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc "The error code of a refused answer."
  def code(conn), do: body(conn)["error"]["code"]
end
