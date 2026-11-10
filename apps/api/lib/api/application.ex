defmodule Api.Application do
  @moduledoc """
  The transport app's supervisor: telemetry, then the one endpoint.

  Everything the endpoint serves is started below it — `Core.PubSub`, Oban
  and the Repo belong to `core` and `data`, which the umbrella starts first
  because `api` depends on them. Nothing else lives here: `api` is transport,
  and a process that holds domain state would be a reason for `core` to reach
  up, which the dependency direction forbids.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Api.Telemetry,
      # Last, so every request it accepts finds the rest already running.
      Api.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Api.Supervisor)
  end

  # Phoenix re-reads the endpoint's config on a hot upgrade.
  @impl Application
  def config_change(changed, _new, removed) do
    Api.Endpoint.config_change(changed, removed)
    :ok
  end
end
