defmodule Core.Workers.InboundSweep do
  @moduledoc """
  The intake log's rows older than 30 days, deleted (AQ-09 §5, QP9-8).
  **Hourly**, on the `retention` queue, like the other sweeps (AQ-04B
  QP4b-2). Holds no rule — it hands the clock to `Core.Inbound.sweep/2`
  — and is idempotent: a second run deletes nothing.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Clock
  alias Core.Inbound

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _gone = Inbound.sweep(Data.Scope.system(), Clock.now())
    :ok
  end
end
