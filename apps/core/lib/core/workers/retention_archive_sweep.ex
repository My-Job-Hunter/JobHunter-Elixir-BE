defmodule Core.Workers.RetentionArchiveSweep do
  @moduledoc """
  Retention (AQ-04B §7.3, QP4b-2): quiet leads, then quiet jobs with no live lead, archived (`Core.Retention.archive/1`). **Hourly**, on the
  `retention` queue: the rules compare dates, so an hourly run does the
  night's work once and catches up after downtime. Holds no rule — it hands
  the clock to `Core.Retention` — and is idempotent: a second run does
  nothing.
  """

  use Oban.Worker, queue: :retention, max_attempts: 3

  alias Core.Clock
  alias Core.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _done = Retention.archive(Clock.now())
    :ok
  end
end
