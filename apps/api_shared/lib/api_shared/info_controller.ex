defmodule ApiShared.InfoController do
  @moduledoc """
  Which app answered, at which API version, from which build. Unauthenticated,
  like the endpoint's own `/info`: it is how a client, or a person with curl,
  checks that a prefix reaches the app it should.
  """

  use Phoenix.Controller, formats: [:json]

  # Read at compile time: a release has no Mix.
  @version Mix.Project.config()[:version]

  def show(conn, _params) do
    json(conn, %{app: conn.assigns.app, api: "v1", version: @version})
  end
end
