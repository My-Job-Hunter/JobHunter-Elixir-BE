defmodule Core.Workers.TaskDueScan do
  @moduledoc """
  Due reminders and overdue notices (AQ-02 §8, QP2-13): every five minutes
  on the `scheduling` queue (`config :core, Oban`). Holds no rule — it hands
  the clock to `Core.Tasks.Due.scan/1` — and is idempotent: the second run
  finds every notice already ensured.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Tasks.Due

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _written = Due.scan(Clock.now())
    :ok
  end
end
