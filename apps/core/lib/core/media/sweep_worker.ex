defmodule Core.Media.SweepWorker do
  @moduledoc """
  Removes media rows reserved more than a day ago whose upload never
  completed (JH-01 §4.1), and their bytes. Daily at 03:20 (`config :core,
  Oban`, the `retention` queue). Holds no rule: it calls
  `Core.Media.sweep_unconfirmed/1` with the clock, and is idempotent — the
  second run finds nothing.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Clock
  alias Core.Media

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _swept = Media.sweep_unconfirmed(Clock.now())
    :ok
  end
end
