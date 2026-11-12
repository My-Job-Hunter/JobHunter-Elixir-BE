defmodule Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The uploads folder exists before the first `PUT /media/:id/blob`, or
    # the boot says why not while somebody is watching.
    Core.Storage.prepare_root!()

    children = [
      # Started before Oban: a worker that broadcasts on completion needs it
      # already running. `Api.Endpoint` names it as its `pubsub_server`.
      {Phoenix.PubSub, name: Core.PubSub},
      # Sweeps expired buckets so the table does not grow with every caller
      # who ever visited.
      {Core.RateLimiter, [clean_period: :timer.minutes(5)]},
      # Configured under `:core` (config/config.exs): queues by purpose, the
      # pruner, the crontab. Inert in tests (`testing: :manual`).
      {Oban, Application.fetch_env!(:core, Oban)}
    ]

    # Every sign-in writes two `guardian_tokens` rows and nothing else deletes
    # an expired one (mCart's `PA6`): the sweeper is what stops the table
    # growing for ever. **Off in tests**, where the SQL sandbox owns the
    # connection and a periodic delete from a process no case checked out
    # would fail rather than sweep.
    Supervisor.start_link(children ++ sweeper(), strategy: :one_for_one, name: Core.Supervisor)
  end

  defp sweeper do
    if Application.get_env(:core, :start_token_sweeper, true), do: [Guardian.DB.Sweeper], else: []
  end
end
