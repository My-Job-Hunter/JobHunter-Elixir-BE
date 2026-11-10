defmodule Notifire.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Nothing to supervise yet: the mailer is a module, not a process, and the
    # delivery workers run under `core`'s Oban when P7 adds them.
    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: Notifire.Supervisor)
  end
end
