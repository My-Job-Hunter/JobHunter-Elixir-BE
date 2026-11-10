defmodule Data.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Data.Repo
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Data.Supervisor)
  end
end
