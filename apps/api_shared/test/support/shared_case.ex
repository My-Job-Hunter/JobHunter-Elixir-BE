defmodule ApiShared.SharedCase do
  @moduledoc """
  For the shared controllers, which have no endpoint of their own: a router
  shaped like every app's (`ApiShared.SharedCase.Router`), driven with
  `Plug.Test`, over the SQL sandbox. `authed/2` puts a genuine bearer token
  on the request, so the pipeline is exercised rather than stubbed.
  """

  use ExUnit.CaseTemplate

  alias Core.Auth.Guardian
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    require ApiShared.Routes

    pipeline :api do
      plug :accepts, ["json"]
      plug ApiShared.Plugs.App, "sharing"
    end

    ApiShared.Routes.shared_pipelines()

    scope "/v1" do
      pipe_through [:api, :jh_shared]
      ApiShared.Routes.shared_routes()
    end

    ApiShared.Routes.not_found_routes()
  end

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import ApiShared.SharedCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Sends a request through the shared router; `params` become the body."
  def request(conn), do: Router.call(conn, Router.init([]))

  @doc "A conn for `method` and `path` with JSON `params`."
  def build(method, path, params \\ %{}) do
    method
    |> Plug.Test.conn(path, params)
    |> Plug.Conn.put_req_header("accept", "application/json")
  end

  @doc "The same, carrying a genuine bearer token for `user`."
  def authed(conn, user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tokens.access_token)
  end

  @doc "The decoded JSON body."
  def body(conn), do: Jason.decode!(conn.resp_body)
end
