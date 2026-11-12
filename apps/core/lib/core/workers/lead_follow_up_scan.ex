defmodule Core.Workers.LeadFollowUpScan do
  @moduledoc """
  Follow-ups that fell due (AQ-04B §6.2): hourly on the `scheduling` queue
  (`config :core, Oban`). Holds no rule — it hands the clock to
  `Core.Leads.FollowUp.scan/1` — and is idempotent: the second run finds
  every notice ensured and every `follow_up_due` written.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Leads.FollowUp

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _done = FollowUp.scan(Clock.now())
    :ok
  end
end
