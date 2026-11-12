defmodule Core.Workers.DigestScan do
  @moduledoc """
  The daily digest at each person's time (AQ-08 §7.4, PLAN §15.7): every
  five minutes on the `scheduling` queue (`config :core, Oban`). Holds no
  rule — it hands the clock to `Core.Notifications.Digests.scan/1` — and is
  idempotent: a second run that day finds each digest already ensured.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Notifications.Digests

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _written = Digests.scan(Clock.now())
    :ok
  end
end
