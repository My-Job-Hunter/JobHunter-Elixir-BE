defmodule Core.Workers.ApprovalReminder do
  @moduledoc """
  One due reminder of an approval (AQ-07 §9, QP7-13) on the `scheduling`
  queue — `due_soon` 24 hours before, `overdue` at the time — planned by
  `Core.Approvals.Reminders.plan/2`. Holds no rule: it hands the clock to
  `Core.Approvals.Reminders.remind/4`, and is idempotent: an approval
  decided, withdrawn or revised since makes it do nothing, and a second
  run finds every notification ensured.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Approvals.Reminders
  alias Core.Clock

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"approval_id" => id, "kind" => kind, "due_at" => at}}) do
    _done = Reminders.remind(id, kind, at, Clock.now())
    :ok
  end
end
