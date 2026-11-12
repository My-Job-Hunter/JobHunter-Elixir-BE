defmodule Core.Workers.ApprovalAutoApprove do
  @moduledoc """
  Auto-approve (AQ-07 §9, QP7-14) on the `scheduling` queue, planned at
  `auto_approve_at` by `Core.Approvals.Reminders.plan/2`. Holds no rule:
  `Core.Approvals.Act.auto_approve/3` approves it only while it is still
  pending at the time planned, so a run after a decision, a revision or a
  second run does nothing.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Approvals.Act
  alias Core.Clock

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"approval_id" => id, "auto_approve_at" => at}}) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)
    _done = Act.auto_approve(id, at, Clock.now())
    :ok
  end
end
