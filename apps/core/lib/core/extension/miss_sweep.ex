defmodule Core.Extension.MissSweep do
  @moduledoc """
  The extension's misses older than 30 days, deleted (AQ-05 §5.2,
  QP5-22). **Hourly**, on the `retention` queue, like the other sweeps
  (AQ-04B QP4b-2). Holds no rule — it hands the clock to
  `Core.Extension.Health.sweep/1` — and is idempotent: a second run
  deletes nothing.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Clock
  alias Core.Extension.Health

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _gone = Health.sweep(Clock.now())
    :ok
  end
end
