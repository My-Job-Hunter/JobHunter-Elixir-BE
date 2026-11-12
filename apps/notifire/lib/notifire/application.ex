defmodule Notifire.Application do
  @moduledoc false

  use Application

  alias Notifire.Push.Outbox

  @impl true
  def start(_type, _args) do
    # The mailer is a module, not a process, and the delivery workers run
    # under `core`'s Oban. The dev push outbox (AQ-08 QP8-16) is the one
    # process, and only where `config :notifire, :push_outbox` turns it on.
    children = if Outbox.on?(), do: [Outbox], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Notifire.Supervisor)
  end
end
