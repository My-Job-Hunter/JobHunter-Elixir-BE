defmodule Core.Workers.ApprovalExpirySweep do
  @moduledoc """
  The expiry sweep (AQ-07 §9, QP7-12), hourly on the `scheduling` queue:
  every approval still pending three days past its due date expires and
  its requester is told. Holds no rule (`Core.Approvals.Act.expire/1`)
  and is idempotent: an expired approval is no longer pending.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Approvals.Act
  alias Core.Clock

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _done = Act.expire(Clock.now())
    :ok
  end
end
